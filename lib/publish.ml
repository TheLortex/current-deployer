let ( let** ) = Lwt_result.bind

module Port = struct
  type t = { source : int; target : int }

  let pp f { source; target } = Fmt.pf f "%d->%d" source target
end

module Published = struct
  type t = { service : string; info : Albatross_deploy.Deployed.t }
  [@@deriving yojson]

  let marshal t = t |> to_yojson |> Yojson.Safe.to_string
  let unmarshal s = s |> Yojson.Safe.from_string |> of_yojson |> Result.get_ok
end

module OpPublish = struct
  type t = No_context

  let id = "mirage-publish"

  module Key = struct
    type t = { service : string }

    let digest t = t.service
  end

  module Value = struct
    type t = {
      ports : Port.t list;
      ip : Ipaddr.V4.t;
      info : Albatross_deploy.Deployed.t;
    }

    let digest { ports; ip; _ } =
      Fmt.str "%a|%a" Ipaddr.V4.pp ip Fmt.(list ~sep:sp Port.pp) ports
      |> Digest.string |> Digest.to_hex
  end

  module Outcome = Published

  let publish No_context job { Key.service } { Value.ports; ip; info } =
    let open Lwt.Syntax in
    let* () = Current.Job.start job ~level:Mostly_harmless in
    Current.Job.log job
      "Register the service %s to ip %a and enable port forwarding" service
      Ipaddr.V4.pp ip;
    (* Set up port forwarning *)
    let ports =
      List.map
        (function
          | { Port.source; target } ->
              { Iptables_daemon_api.Types.PortRedirection.source; target })
        ports
    in
    let** socket =
      Utils.catch_as_msg "exception when connecting to iptables daemon"
        (Client.connect ())
    in
    let** result =
      Lwt.finalize
        (fun () ->
          Client.Deployments.create ~socket
            {
              (* todo: a bit flaky here *)
              Iptables_daemon_api.Types.DeploymentInfo.ip =
                { tag = service; ip };
              ports;
              name = service;
            }
          |> Lwt.map Utils.remap_errors)
        (fun () -> Client.close socket)
    in
    let** () = Lwt.return (result |> Utils.remap_errors) in

    Lwt_result.return { Published.service; info }

  let pp f (key, _v) = Fmt.pf f "@[<v2>deploy %s@]" key.Key.service
  let auto_cancel = true
end

module Publish = Current_cache.Output (OpPublish)

let publish ~service ?(ports = []) info =
  let open Current.Syntax in
  Current.component "Publish %s\n%a" service Fmt.(list Port.pp) ports
  |> let> info = info in
     Publish.set No_context { service }
       { ports; ip = info.Albatross_deploy.Deployed.config.ip; info }
