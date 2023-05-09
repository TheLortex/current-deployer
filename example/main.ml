module Git = Current_git
module Docker = Current_docker.Default
module Deployer = Current_albatross_deployer

let pipeline () =
  let open Current.Syntax in
  let git =
    Git.Local.v Fpath.(v "/home/lucas/mirage/egarim/dns-resolver.git/")
  in
  let src = Git.Local.commit_of_ref git "refs/heads/master" in
  let dockerfile = Current.return (`File (Fpath.v "Dockerfile")) in
  let image =
    Docker.build (`Git src)
      ~build_args:[ "--build-arg"; "TARGET=hvt" ]
      ~dockerfile ~label:"docker-build" ~pull:true
  in
  let get_ip =
    Deployer.get_ip
      ~blacklist:[ Ipaddr.V4.of_string_exn "10.0.0.1" ]
      ~prefix:(Ipaddr.V4.Prefix.of_string_exn "10.0.0.0/24")
  in

  (* 3: forward *)
  let config_forward =
    let+ unikernel =
      Deployer.Unikernel.of_docker ~location:(Fpath.v "/unikernel.hvt") image
    in
    {
      Deployer.Config.Pre.service = "service-forwarder";
      unikernel;
      args =
        (fun ip ->
          [
            "--ipv4=" ^ Ipaddr.V4.to_string ip ^ "/24";
            "--ipv4-gateway=10.0.0.2";
            "-l";
            "error";
          ]);
      memory = 256;
      network = Some "br0";
      cpu = 0;
    }
  in
  let ip_forward = get_ip config_forward in
  let config_forward =
    let+ ip_forward = ip_forward and+ config_forward = config_forward in
    Deployer.Config.v config_forward ip_forward
  in
  (* 2: dkim signer *)
  let config_signer =
    let+ unikernel =
      Deployer.Unikernel.of_docker ~location:(Fpath.v "/unikernel.hvt") image
    and+ ip_forward = ip_forward in
    {
      Deployer.Config.Pre.service = "service-signer";
      unikernel;
      args =
        (fun ip ->
          [
            "--ipv4=" ^ Ipaddr.V4.to_string ip ^ "/24";
            "--ipv4-gateway=" ^ Ipaddr.V4.to_string ip_forward
            (*fake stuff here*);
          ]);
      memory = 256;
      network = Some "br0";
      cpu = 0;
    }
  in
  let ip_signer = get_ip config_signer in
  let config_signer =
    let+ ip_signer = ip_signer and+ config_signer = config_signer in
    Deployer.Config.v config_signer ip_signer
  in
  (* 1: entry *)
  let config_entry =
    let+ unikernel =
      Deployer.Unikernel.of_docker ~location:(Fpath.v "/unikernel.hvt") image
    and+ ip_signer = ip_signer in
    {
      Deployer.Config.Pre.service = "service-entry";
      unikernel;
      args =
        (fun ip ->
          [
            "--ipv4=" ^ Ipaddr.V4.to_string ip ^ "/24";
            "--ipv4-gateway=" ^ Ipaddr.V4.to_string ip_signer;
            "--bad-option";
            (*fake stuff here*)
          ]);
      memory = 256;
      network = Some "br0";
      cpu = 0;
    }
  in
  let ip_entry = get_ip config_entry in
  let config_entry =
    let+ ip_entry = ip_entry and+ config_entry = config_entry in
    Deployer.Config.v config_entry ip_entry
  in
  (* Deployments *)
  let deploy_forward =
    Deployer.deploy_albatross ~label:"forward" config_forward
  in
  let deploy_signer = Deployer.deploy_albatross ~label:"signer" config_signer in
  let deploy_entry = Deployer.deploy_albatross ~label:"entry" config_entry in
  (* Publish: staged *)
  let teleporter =
    [ deploy_forward; deploy_entry; deploy_signer ]
    |> List.map Current.ignore_value
    |> Current.all
    |> Stager.activate ~id:"email stack"
  in

  let staged_forward =
    Stager.stage_auto ~id:"forward"
      (module Deployer.Deployed)
      teleporter deploy_forward
  in
  let staged_signer =
    Stager.stage_auto ~id:"signer"
      (module Deployer.Deployed)
      teleporter deploy_signer
  in
  let staged_entry =
    Stager.stage_auto ~id:"entry"
      (module Deployer.Deployed)
      teleporter deploy_entry
  in
  let publish_no_ports =
    [
      ("forward-live", staged_forward.live);
      ("forward-current", staged_forward.current);
      ("signer-live", staged_signer.live);
      ("signer-current", staged_signer.current);
    ]
    |> List.map (fun (service, current) -> Deployer.publish ~service current)
  in
  let publish_entry_live =
    Deployer.publish ~service:"entry-live"
      ~ports:[ { Deployer.Port.source = 25; target = 25 } ]
      staged_entry.live
  in
  let publish_entry_current =
    Deployer.publish ~service:"entry-current"
      ~ports:[ { Deployer.Port.source = 2525; target = 25 } ]
      staged_entry.current
  in
  let all_deployments =
    Current.list_seq
      (publish_entry_live :: publish_entry_current :: publish_no_ports)
  in
  let all_unikernels_monitors =
    [ staged_forward; staged_signer; staged_entry ]
    |> List.map (fun (t : _ Stager.staged) -> [ t.live; t.current ])
    |> List.concat |> List.map Deployer.monitor
    |> List.map Deployer.is_running
    |> Current.all
  in
  Current.all [ Deployer.collect all_deployments; all_unikernels_monitors ]

let () =
  Logs.(set_level (Some Info));
  Logs.set_reporter (Logs_fmt.reporter ())

let main config mode =
  let engine = Current.Engine.create ~config pipeline in
  let routes = Current_web.routes engine in
  let site =
    Current_web.Site.v ~has_role:Current_web.Site.allow_all
      ~name:"OCurrent Deployer" routes
  in
  Lwt.choose
    [
      Current.Engine.thread engine;
      (* The main thread evaluating the pipeline. *)
      Current_web.run ~mode site;
    ]
  |> Lwt_main.run
  |> function
  | Ok _ as x -> x
  | Error (`Msg e) -> Error e

(* Command-line parsing *)

open Cmdliner

let cmd =
  let doc = "build and deploy services from Git" in
  Cmd.v (Cmd.info "deploy" ~doc)
    Term.(const main $ Current.Config.cmdliner $ Current_web.cmdliner)

let () = exit Cmd.(eval_result cmd)
