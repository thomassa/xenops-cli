(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xenops_interface
open Xenops_client

let ( |> ) a b = b a

let usage () =
	Printf.fprintf stderr "%s <command> [args] - send commands to the xenops daemon\n" Sys.argv.(0);
	Printf.fprintf stderr "%s add <config> - add a VM from <config>\n" Sys.argv.(0);
	Printf.fprintf stderr "%s list [verbose] - query the states of known VMs\n" Sys.argv.(0);
	Printf.fprintf stderr "%s remove <name or id> - forget about a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s start <name or id> [paused] - start a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s pause <name or id> - pause a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s unpause <name or id> - unpause a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s shutdown <name or id> - shutdown a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s reboot <name or id> - reboot a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s suspend <name or id> <disk> - suspend a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s resume <name or id> <disk> - resume a VM\n" Sys.argv.(0);
	Printf.fprintf stderr "%s migrate <name or id> <url> - migrate a VM to <url>\n" Sys.argv.(0);
	Printf.fprintf stderr "%s vbd-list <name or id> - query the states of a VM's block devices\n" Sys.argv.(0);
	Printf.fprintf stderr "%s console-list <name or id> - query the states of a VM's consoles\n" Sys.argv.(0);
	Printf.fprintf stderr "%s pci-add <name or id> <number> <bdf> - associate the PCI device <bdf> with <name or id>\n" Sys.argv.(0);
	Printf.fprintf stderr "%s pci-remove <name or id> <number> - disassociate the PCI device <bdf> with <name or id>\n" Sys.argv.(0);
	Printf.fprintf stderr "%s pci-list <name or id> - query the states of a VM's PCI devices\n" Sys.argv.(0);
	Printf.fprintf stderr "%s cd-insert <id> <disk> - insert a CD into a VBD\n" Sys.argv.(0);
	Printf.fprintf stderr "%s cd-eject <id> - eject a CD from a VBD\n" Sys.argv.(0);
	Printf.fprintf stderr "%s export-metadata <id> - export metadata associated with <id>\n" Sys.argv.(0);
	Printf.fprintf stderr "%s export-metadata-xm <id> - export metadata associated with <id> in xm format\n" Sys.argv.(0);
	Printf.fprintf stderr "%s delay <id> <time> - add an explicit delay of length <time> to this VM's queue\n" Sys.argv.(0);
	Printf.fprintf stderr "%s events-watch - display all events generated by the server\n" Sys.argv.(0);
	Printf.fprintf stderr "%s set-worker-pool-size <threads> - set the size of the worker pool\n" Sys.argv.(0);
	Printf.fprintf stderr "%s diagnostics - display diagnostic information\n" Sys.argv.(0);
	Printf.fprintf stderr "%s task-list - display the state of all known tasks\n" Sys.argv.(0);
	Printf.fprintf stderr "%s shutdown - shutdown the xenops service\n" Sys.argv.(0);
	()

let dbg = "xn"

let finally f g =
	try
		let result = f () in
		g ();
		result
	with e ->
		g ();
		raise e

(* Grabs the result from a task and destroys it *)
let success_task f id =
	finally
		(fun () ->
			let t = Client.TASK.stat dbg id in
			match t.Task.state with
				| Task.Completed _ -> f t
				| Task.Failed x ->
					let exn = exn_of_exnty (Exception.exnty_of_rpc x) in
					begin match exn with
						| Failed_to_contact_remote_service x ->
							Printf.printf "Failed to contact remote service on: %s\n" x;
							Printf.printf "Check the address and credentials.\n";
							exit 1;
						| _ -> raise exn
					end
				| Task.Pending _ -> failwith "task pending"
		) (fun () ->
			Client.TASK.destroy dbg id
		)

let parse_source x = match List.filter (fun x -> x <> "") (Re_str.split (Re_str.regexp "[:]") x) with
	| [ "phy"; path ] -> Some (Local path)
	| [ "sm"; path ] -> Some (VDI path)
	| [ "file"; path ] ->
		Printf.fprintf stderr "I don't understand 'file' disk paths. Please use 'phy'.\n";
		exit 2
	| [] -> None (* empty *)
	| _ ->
		Printf.fprintf stderr "I don't understand '%s'. Please use 'phy:path,...\n" x;
		exit 2

let print_source = function
	| None -> ""
	| Some (Local path) -> Printf.sprintf "phy:%s" path
	| Some (VDI path) -> Printf.sprintf "sm:%s" path

let print_pci x =
	let open Pci in
	let open Xn_cfg_types in
	let msi = match x.msitranslate with
		| None -> ""
		| Some true -> Printf.sprintf ",%s=1" _msitranslate
		| Some false -> Printf.sprintf ",%s=0" _msitranslate in
	let power = match x.power_mgmt with
		| None -> ""
		| Some true -> Printf.sprintf ",%s=1" _power_mgmt
		| Some false -> Printf.sprintf ",%s=0" _power_mgmt in
	Printf.sprintf "%04x:%02x:%02x.%01x%s%s" x.domain x.bus x.dev x.fn msi power

let parse_pci vm_id (x, idx) = match Re_str.split (Re_str.regexp "[,]") x with
	| bdf :: options ->
		let hex x = int_of_string ("0x" ^ x) in
		let parse_dev_fn x = match Re_str.split (Re_str.regexp "[.]") x with
			| [ dev; fn ] -> hex dev, hex fn
			| _ ->
				Printf.fprintf stderr "Failed to parse BDF: %s. It should be '[DDDD:]BB:VV.F'\n" bdf;
				exit 2 in
		let domain, bus, dev, fn = match Re_str.split (Re_str.regexp "[:]") bdf with
			| [ domain; bus; dev_dot_fn ] ->
				let dev, fn = parse_dev_fn dev_dot_fn in
				hex domain, hex bus, dev, fn
			| [ bus; dev_dot_fn ] ->
				let dev, fn = parse_dev_fn dev_dot_fn in
				0, hex bus, dev, fn
			| _ ->
				Printf.fprintf stderr "Failed to parse BDF: %s. It should be '[DDDD:]BB:VV.F'\n" bdf;
				exit 2 in
		let options = List.map (fun x -> match Re_str.bounded_split (Re_str.regexp "[=]") x 2 with
			| [k; v] -> k, v
			| _ ->
				Printf.fprintf stderr "Failed to parse PCI option: %s. It should be key=value.\n" x;
				exit 2
		) options in
		let bool_opt k opts =
			if List.mem_assoc k opts then Some (List.assoc k opts = "1") else None in
		let open Pci in
		let open Xn_cfg_types in
		let msitranslate = bool_opt _msitranslate options in
		let power_mgmt = bool_opt _power_mgmt options in
		{
			Pci.id = vm_id, string_of_int idx;
			position = idx;
			domain = domain;
			bus = bus;
			dev = dev;
			fn = fn;
			msitranslate = msitranslate;
			power_mgmt = power_mgmt
		}
	| _ ->
		Printf.fprintf stderr "Failed to parse PCI '%s'. It should be '[DDDD:]BB:VV.F[,option1[,option2]]'." x;
		exit 2

let print_disk vbd =
	let device_number = snd vbd.Vbd.id in
	let mode = match vbd.Vbd.mode with
		| Vbd.ReadOnly -> "r"
		| Vbd.ReadWrite -> "w" in
	let ty = match vbd.Vbd.ty with
		| Vbd.CDROM -> ":cdrom"
		| Vbd.Disk -> "" in
	let source = print_source vbd.Vbd.backend in
	Printf.sprintf "%s,%s%s,%s" source device_number ty mode

let parse_disk vm_id x = match Re_str.split (Re_str.regexp "[,]") x with
	| [ source; device_number; rw ] ->
		let ty, device_number, device_number' = match Re_str.split (Re_str.regexp "[:]") device_number with
			| [ x ] -> Vbd.Disk, x, Device_number.of_string false x
			| [ x; "cdrom" ] -> Vbd.CDROM, x, Device_number.of_string false x
			| _ ->
				Printf.fprintf stderr "Failed to understand disk name '%s'. It should be 'xvda' or 'hda:cdrom'\n" device_number;
				exit 2 in
		let mode = match String.lowercase rw with
			| "r" -> Vbd.ReadOnly
			| "w" -> Vbd.ReadWrite
			| x ->
				Printf.fprintf stderr "Failed to understand disk mode '%s'. It should be 'r' or 'w'\n" x;
				exit 2 in
		let backend = parse_source source in
		{
			Vbd.id = vm_id, device_number;
			position = Some device_number';
			mode = mode;
			backend = backend;
			ty = ty;
			unpluggable = true;
			extra_backend_keys = [];
			extra_private_keys = [];
			qos = None;
		}
	| _ ->
		Printf.fprintf stderr "I don't understand '%s'. Please use 'phy:path,xvda,w'\n" x;
		exit 2

let print_disk vbd =
	let device_number = snd vbd.Vbd.id in
	let mode = match vbd.Vbd.mode with
		| Vbd.ReadOnly -> "r"
		| Vbd.ReadWrite -> "w" in
	let ty = match vbd.Vbd.ty with
		| Vbd.CDROM -> ":cdrom"
		| Vbd.Disk -> "" in
	let source = print_source vbd.Vbd.backend in
	Printf.sprintf "%s,%s%s,%s" source device_number ty mode

let print_vif vif =
	let mac = if vif.Vif.mac = "" then "" else Printf.sprintf "mac=%s" vif.Vif.mac in
	let bridge = match vif.Vif.backend with
		| Network.Local x -> Printf.sprintf "bridge=%s" x
		| Network.Remote (_, _) ->
			Printf.fprintf stderr "Cannot handle backend = Netback(_, _)\n%!";
			exit 2 in
	String.concat "," [ mac; bridge ]

let parse_vif vm_id (x, idx) =
	let open Xn_cfg_types in
	let xs = List.filter (fun x -> x <> "") (Re_str.split (Re_str.regexp_string "[ \t]*,[ \t]*") x) in
	let kvpairs = List.map (fun x -> match Re_str.bounded_split (Re_str.regexp "[=]") x 2 with
		| [ k; v ] -> k, v
		| _ ->
			Printf.fprintf stderr "I don't understand '%s'. Please use 'mac=xx:xx:xx:xx:xx:xx,bridge=xenbrX'.\n" x;
			exit 2
	) xs in {
		Vif.id = vm_id, string_of_int idx;
		position = idx;
		mac = if List.mem_assoc _mac kvpairs then List.assoc _mac kvpairs else "";
		carrier = true;
		mtu = 1500;
		rate = None;
		backend = if List.mem_assoc _bridge kvpairs then Network.Local (List.assoc _bridge kvpairs) else Network.Local "xenbr0";
		other_config = [];
		locking_mode = Vif.Unlocked;
		extra_private_keys = [];
	}

let print_vm id =
	let open Xn_cfg_types in
	let open Vm in
	let vm_t, _ = Client.VM.stat dbg id in
	let quote x = Printf.sprintf "'%s'" x in
	let boot = match vm_t.ty with
		| PV { boot = boot } ->
			begin match boot with
				| Direct { kernel = k; cmdline = c; ramdisk = i } -> [
					_builder, quote "linux";
					_kernel, quote k;
					_root, quote c
				] @ (match i with
				| None -> []
				| Some x -> [ _ramdisk, x ])
				| Indirect { bootloader = b } -> [
					_builder, quote "linux";
					_bootloader, quote b;
				]
			end
		| HVM { boot_order = b } -> [
			_builder, quote "hvmloader";
			_boot, quote b
		] in
	let name = [ _name, quote vm_t.name ] in
	let vcpus = [ _vcpus, string_of_int vm_t.vcpus ] in
	let bytes_to_mib x = Int64.div x (Int64.mul 1024L 1024L) in
	let memory = [ _memory, vm_t.memory_static_max |> bytes_to_mib |> Int64.to_string ] in
	let vbds = Client.VBD.list dbg id |> List.map fst in
	let vbds = [ _disk, Printf.sprintf "[ %s ]" (String.concat ", " (List.map (fun x -> Printf.sprintf "'%s'" (print_disk x)) vbds)) ] in
	let vifs = Client.VIF.list dbg id |> List.map fst in
	let vifs = [ _vif, Printf.sprintf "[ %s ]" (String.concat ", " (List.map (fun x -> Printf.sprintf "'%s'" (print_vif x)) vifs)) ] in
	let pcis = Client.PCI.list dbg id |> List.map fst in
	(* Sort into order based on position *)
	let pcis = List.sort (fun a b -> compare a.Pci.position b.Pci.position) pcis in
	let pcis = [ _pci, Printf.sprintf "[ %s ]" (String.concat ", " (List.map (fun x -> Printf.sprintf "'%s'" (print_pci x)) pcis)) ] in
	let global_pci_opts = [
		_vm_pci_msitranslate, if vm_t.pci_msitranslate then "1" else "0";
		_vm_pci_power_mgmt, if vm_t.pci_power_mgmt then "1" else "0";
	] in

	String.concat "\n" (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v)
		(name @ boot @ vcpus @ memory @ vbds @ vifs @ pcis @ global_pci_opts))


let add filename =
	let ic = open_in filename in
	finally
		(fun () ->
			let lexbuf = Lexing.from_channel ic in
			let config = Xn_cfg_parser.file Xn_cfg_lexer.token lexbuf in
			let open Xn_cfg_types in
			let mem x = List.mem_assoc x config in
			let find x = List.assoc x config in
			let any xs = List.fold_left (||) false (List.map mem xs) in
			let pv =
				false
				|| (mem _builder && (find _builder |> string = "linux"))
				|| (not(mem _builder) && (any [ _bootloader; _kernel ])) in
			let open Vm in
			let builder_info = match pv with
				| true -> PV {
					framebuffer = false;
					framebuffer_ip = Some "0.0.0.0";
					vncterm = true;
					vncterm_ip = Some "0.0.0.0";
					boot =
						if mem _bootloader then Indirect {
							bootloader = find _bootloader |> string;
							extra_args = "";
							legacy_args = "";
							bootloader_args = "";
							devices = [];
						} else if mem _kernel then Direct {
							kernel = find _kernel |> string;
							cmdline = if mem _root then find _root |> string else "";
							ramdisk = if mem _ramdisk then Some (find _ramdisk |> string) else None;
						} else begin
							List.iter (Printf.fprintf stderr "%s\n") [
								"I couldn't determine how to start this VM.";
								Printf.sprintf "A PV guest needs either %s or %s and %s" _bootloader _kernel _ramdisk
							];
							exit 1
						end;
					}
				| false -> HVM {
					hap = true;
					shadow_multiplier = 1.;
					timeoffset = "";
					video_mib = 4;
					video = Cirrus;
					acpi = true;
					serial = None;
					keymap = None;
					vnc_ip = Some "0.0.0.0";
					pci_emulations = [];
					pci_passthrough = false;
					boot_order = if mem _boot then find _boot |> string else "cd";
					qemu_disk_cmdline = false;
					qemu_stubdom = false;
				} in
			let uuid = if mem _uuid then find _uuid |> string else Uuidm.to_string (Uuidm.create `V4) in
			let name = if mem _name then find _name |> string else uuid in
			let mib = if mem _memory then find _memory |> int |> Int64.of_int else 64L in
			let bytes = Int64.mul 1024L (Int64.mul 1024L mib) in
			let vcpus = if mem _vcpus then find _vcpus |> int else 1 in
			let pci_msitranslate = if mem _vm_pci_msitranslate then find _vm_pci_msitranslate |> bool else true in
			let pci_power_mgmt = if mem _vm_pci_power_mgmt then find _vm_pci_power_mgmt |> bool else false in
			let vm = {
				id = uuid;
				name = name;
				ssidref = 0l;
				xsdata = [];
				platformdata = [ (* HVM defaults *)
					"nx", "false";
					"acpi", "true";
					"apic", "true";
					"pae", "true";
					"viridian", "true";
				];
				bios_strings = [];
				ty = builder_info;
				suppress_spurious_page_faults = false;
				machine_address_size = None;
				memory_static_max = bytes;
				memory_dynamic_max = bytes;
				memory_dynamic_min = bytes;
				vcpu_max = vcpus;
				vcpus = vcpus;
				scheduler_params = { priority = None; affinity = [] };
				on_crash = [ Vm.Shutdown ];
				on_shutdown = [ Vm.Shutdown ];
				on_reboot = [ Vm.Start ];
				pci_msitranslate = pci_msitranslate;
				pci_power_mgmt = pci_power_mgmt;
			} in
			let (id: Vm.id) = Client.VM.add dbg vm in
			let disks = if mem _disk then find _disk |> list string else [] in
			let one x = x |> parse_disk id |> Client.VBD.add dbg in
			let (_: Vbd.id list) = List.map one disks in
			let vifs = if mem _vif then find _vif |> list string else [] in
			let rec ints first last = if first > last then [] else first :: (ints (first + 1) last) in
			let vifs = List.combine vifs (ints 0 (List.length vifs - 1)) in
			let one x = x |> parse_vif id |> Client.VIF.add dbg in
			let (_: Vif.id list) = List.map one vifs in
			let pcis = if mem _pci then find _pci |> list string else [] in
			let pcis = List.combine pcis (ints 0 (List.length pcis - 1)) in
			let one x = x |> parse_pci id |> Client.PCI.add dbg in
			let (_: Pci.id list) = List.map one pcis in
			Printf.printf "%s\n" id
		)
		(fun () -> close_in ic)

let string_of_power_state = function
	| Running   -> "Running"
	| Suspended -> "Suspend"
	| Halted    -> "Halted "
	| Paused    -> "Paused "

let list_verbose () =
	let open Vm in
	let vms = Client.VM.list dbg () in
	List.iter
		(fun (vm, state) ->
			Printf.printf "%-45s%-5s\n"  vm.name (state.power_state |> string_of_power_state);
			Printf.printf "  %s\n" (vm |> rpc_of_t |> Jsonrpc.to_string);
			Printf.printf "  %s\n" (state |> rpc_of_state |> Jsonrpc.to_string);
		) vms

let list_compact () =
	let open Vm in
	let line name domid mem vcpus state time =
		Printf.sprintf "%-45s%-5s%-6s%-5s     %-8s%-s" name domid mem vcpus state time in
	let header = line "Name" "ID" "Mem" "VCPUs" "State" "Time(s)" in
	let string_of_vm (vm, state) =
		let domid = match state.Vm.power_state with
			| Running -> String.concat "," (List.map string_of_int state.Vm.domids)
			| _ -> "-" in
		let mem = Int64.to_string (Int64.div (Int64.div vm.memory_static_max 1024L) 1024L) in
		let vcpus = string_of_int state.vcpu_target in
		let state = state.Vm.power_state |> string_of_power_state in
		line vm.name domid mem vcpus state "" in
	let vms = Client.VM.list dbg () in
	let lines = header :: (List.map string_of_vm vms) in
	List.iter (Printf.printf "%s\n") lines

let diagnose_error f =
	try
		f ()
	with e ->
		Printf.fprintf stderr "Caught exception: %s\n" (Printexc.to_string e);
		begin match e with
		| Unix.Unix_error(Unix.EACCES, _, _) ->
			Printf.fprintf stderr "Access was denied (EACCES).\n";
			let uid = Unix.geteuid () in
			if uid <> 0 then begin
				Printf.fprintf stderr "My effective uid is %d.\n" uid;
				Printf.fprintf stderr "\nPlease switch to root (uid 0) and retry.\n";
				exit 1
			end else begin
				Printf.fprintf stderr "I observe that my effective uid is 0 (i.e. I'm running as root).\n";
				Printf.fprintf stderr "\nInvestigate the settings of any active security software (selinux) and retry.\n";
				exit 1;
			end
		| Unix.Unix_error(Unix.ECONNREFUSED, _, _) ->
			Printf.fprintf stderr "Connection to the server was refused (ECONNREFUSED).\n";
			Printf.fprintf stderr "\nPlease start (or restart) the xenopsd service and retry.\n";
			exit 1;
		| Unix.Unix_error(Unix.ENOENT, _, _) ->
			Printf.fprintf stderr "The server socket does not exist (ENOENT).\n";
			Printf.fprintf stderr "\nPossible fixes include:\n";
			Printf.fprintf stderr "1. Start the xenopsd service; it will create the socket when it is started;\n";
			Printf.fprintf stderr "2. Override the default path using the --socket=<path> option;\n";
			exit 1;
		| _ ->
			Printf.fprintf stderr "I don't have any relevant diagnostic advice. Please re-read the documentation\nand if you can't resolve the problem, send an email to <xen-api@lists.xen.org>.\n";
			exit 1
		end

let list copts = diagnose_error (if copts.Common.verbose then list_verbose else list_compact)

type t =
	| Line of string
	| Block of t list
let pp x =
	let open Rpc in
	let rec to_string_list = function
		| Line x -> [ x ]
		| Block xs ->
			let xs' = List.map to_string_list xs |> List.concat in
			List.map (fun x -> "    " ^ x) xs' in
	let flatten xs =
		let rec aux line = function
			| Line x :: xs -> aux (if line <> "" then line ^ " " ^ x else x) xs
			| Block x :: xs ->
				(if line <> "" then [ Line line ] else []) @ [ Block (aux "" x) ] @ (aux "" xs)
			| [] ->
				if line <> "" then [ Line line ] else [] in
		aux "" xs in
	let rec to_t = function
		| Int x -> [ Line (Printf.sprintf "%Ld" x) ]
		| Bool x -> [ Line (Printf.sprintf "%b" x) ]
		| Float x -> [ Line (Printf.sprintf "%g" x) ]
		| String x -> [ Line x ]
		| DateTime x -> [ Line x ]
		| Enum [] -> [ Line "[]" ]
		| Enum xs -> [ Line "["; Block (List.concat (List.map to_t xs)); Line "]" ]
		| Dict [] -> [ Line "{}" ]
		| Dict xs -> [ Line "{"; Block (List.concat (List.map (fun (s, t) -> Line (s ^ ": ") :: to_t t) xs)); Line "}" ]
		| Null -> [] in
	x |> to_t |> flatten |> List.map to_string_list |> List.concat |> List.iter (Printf.printf "%s\n")

let diagnostics () =
	Client.get_diagnostics dbg () |> Jsonrpc.of_string |> pp

let find_by_name x =
	let open Vm in
	let all = Client.VM.list dbg () in
	let this_one (y, _) = y.id = x || y.name = x in
	try
		List.find this_one all
	with Not_found ->
		Printf.fprintf stderr "Failed to find VM: %s\n" x;
		exit 1

let remove x =
	let open Vm in
	let vm, _ = find_by_name x in
	let vbds = Client.VBD.list dbg vm.id in
	List.iter
		(fun (vbd, _) ->
			Client.VBD.remove dbg vbd.Vbd.id
		) vbds;
	let vifs = Client.VIF.list dbg vm.id in
	List.iter
		(fun (vif, _) ->
			Client.VIF.remove dbg vif.Vif.id
		) vifs;
	Client.VM.remove dbg vm.id

let export_metadata x filename =
	let open Vm in
	let vm, _ = find_by_name x in
	let txt = Client.VM.export_metadata dbg vm.id in
	let oc = open_out filename in
	finally
		(fun () ->
			output_string oc txt
		) (fun () -> close_out oc)

let export_metadata_xm x filename =
	let open Vm in
	let vm, _ = find_by_name x in
	let txt = print_vm vm.id in
	let oc = open_out filename in
	finally
		(fun () ->
			output_string oc txt
		) (fun () -> close_out oc)

let delay x t =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.delay dbg vm.id t |> wait_for_task dbg |> success_task ignore_task

let import_metadata filename =
	let ic = open_in filename in
	let buf = Buffer.create 128 in
	let line = String.make 128 '\000' in
	finally
		(fun () ->
			try
				while true do
					let n = input ic line 0 (String.length line) in
					Buffer.add_string buf (String.sub line 0 n)
				done
				with End_of_file -> ()
		) (fun () -> close_in ic);
	let txt = Buffer.contents buf in
	let id = Client.VM.import_metadata dbg txt in
	Printf.printf "%s\n" id

let start copts paused = function
	| None -> `Error (false, "You must supply a VM name or UUID")
	| Some x ->
		let open Vm in
		let vm, _ = find_by_name x in
		Client.VM.start dbg vm.id |> wait_for_task dbg |> success_task ignore_task;
		if not paused
		then Client.VM.unpause dbg vm.id |> wait_for_task dbg |> success_task ignore_task;
		`Ok ()

let shutdown x timeout =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.shutdown dbg vm.id timeout |> wait_for_task dbg

let pause x =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.pause dbg vm.id |> wait_for_task dbg

let unpause x =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.unpause dbg vm.id |> wait_for_task dbg

let reboot x timeout =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.reboot dbg vm.id timeout |> wait_for_task dbg

let suspend x disk =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.suspend dbg vm.id (Local disk) |> wait_for_task dbg

let resume x disk =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.resume dbg vm.id (Local disk) |> wait_for_task dbg

let migrate x url =
	let open Vm in
	let vm, _ = find_by_name x in
	Client.VM.migrate dbg vm.id [] [] url |> wait_for_task dbg

let trim limit str =
	let l = String.length str in
	if l < limit then str
	else
		"..." ^ (String.sub str (l - limit + 3) (limit - 3))

let vbd_list x =
	let vm, _ = find_by_name x in
	let vbds = Client.VBD.list dbg vm.Vm.id in
	let line id position mode ty plugged disk disk2 =
		Printf.sprintf "%-10s %-8s %-4s %-5s %-7s %-35s %-35s " id position mode ty plugged disk disk2 in
	let header = line "id" "position" "mode" "type" "plugged" "disk" "xenstore_disk" in
	let lines = List.map
		(fun (vbd, state) ->
			let id = snd vbd.Vbd.id in
			let position = match vbd.Vbd.position with
				| None -> "None"
				| Some x -> Device_number.to_linux_device x in
			let mode = if vbd.Vbd.mode = Vbd.ReadOnly then "RO" else "RW" in
			let ty = match vbd.Vbd.ty with Vbd.CDROM -> "CDROM" | Vbd.Disk -> "HDD" in
			let plugged = if state.Vbd.plugged then "X" else " " in
			let disk = match vbd.Vbd.backend with
				| None -> ""
				| Some (Local x) -> x |> trim 32
				| Some (VDI path) -> path |> trim 32 in
			let info = Client.VBD.stat dbg (vbd.Vbd.id) in
			let disk2 = match (snd info).Vbd.backend_present with
				| None -> ""
				| Some (Local x) -> x |> trim 32
				| Some (VDI path) -> path |> trim 32 in
			line id position mode ty plugged disk disk2
		) vbds in
	List.iter print_endline (header :: lines)

let console_list x =
	let _, s = find_by_name x in
	let line protocol port =
		Printf.sprintf "%-10s %-6s" protocol port in
	let header = line "protocol" "port" in
	let lines = List.map
		(fun c ->
			let protocol = match c.Vm.protocol with
				| Vm.Rfb -> "RFB"
				| Vm.Vt100 -> "VT100" in
			line protocol (string_of_int c.Vm.port)
		) s.Vm.consoles in
	List.iter print_endline (header :: lines)

let pci_add x idx bdf =
	let vm, _ = find_by_name x in
	let open Pci in
	let domain, bus, dev, fn = Scanf.sscanf bdf "%04x:%02x:%02x.%1x" (fun a b c d -> a, b, c, d) in
	let id = Client.PCI.add dbg {
		id = (vm.Vm.id, idx);
		position = int_of_string idx;
		domain = domain;
		bus = bus;
		dev = dev;
		fn = fn;
		msitranslate = None;
		power_mgmt = None
	} in
	Printf.printf "%s.%s\n" (fst id) (snd id)

let pci_remove x idx =
	let vm, _ = find_by_name x in
	Client.PCI.remove dbg (vm.Vm.id, idx)

let pci_list x =
	let vm, _ = find_by_name x in
	let pcis = Client.PCI.list dbg vm.Vm.id in
	let line id bdf =
		Printf.sprintf "%-10s %-3s %-12s" id bdf in
	let header = line "id" "pos" "bdf" in
	let lines = List.map
		(fun (pci, state) ->
			let open Pci in
			let id = snd pci.id in
			let bdf = Printf.sprintf "%04x:%02x:%02x.%01x" pci.domain pci.bus pci.dev pci.fn in
			line id (string_of_int pci.position) bdf
		) pcis in
	List.iter print_endline (header :: lines)

let find_vbd id =
	let vbd_id : Vbd.id = match Re_str.bounded_split (Re_str.regexp "[.]") id 2 with
		| [ a; b ] -> a, b
		| _ ->
			Printf.fprintf stderr "Failed to parse VBD id: %s (expected VM.device)\n" id;
			exit 1 in
	let vm_id = fst vbd_id in
	let vm, _ = find_by_name vm_id in
	let vbds = Client.VBD.list dbg vm.Vm.id in
	let this_one (y, _) = snd y.Vbd.id = snd vbd_id in
	try
		List.find this_one vbds
	with Not_found ->
		Printf.fprintf stderr "Failed to find VBD: %s\n" id;
		exit 1

let cd_eject id =
	let vbd, _ = find_vbd id in
	Client.VBD.eject dbg vbd.Vbd.id |> wait_for_task dbg

let cd_insert id disk =
	let vbd, _ = find_vbd id in
	match parse_source disk with
	| None ->
		Printf.fprintf stderr "Cannot insert a disk which doesn't exist\n";
		exit 1
	| Some backend ->
		Client.VBD.insert dbg vbd.Vbd.id backend |> wait_for_task dbg

let rec events_watch from =
	let events, next = Client.UPDATES.get dbg from None in
	let open Dynamic in
	let lines = List.map
		(function
			| Vm id ->
				Printf.sprintf "VM %s" id
			| Vbd id ->
				Printf.sprintf "VBD %s.%s" (fst id) (snd id)
			| Vif id ->
				Printf.sprintf "VIF %s.%s" (fst id) (snd id)
			| Pci id ->
				Printf.sprintf "PCI %s.%s" (fst id) (snd id)
			| Task id ->
				Printf.sprintf "Task %s" id
			| Barrier id ->
				Printf.sprintf "Barrier %d" id
		) events in
	List.iter (fun x -> Printf.printf "%-8d %s\n" next x) lines;
	flush stdout;
	events_watch (Some next)

let set_worker_pool_size size =
	Client.HOST.set_worker_pool_size dbg size

let print_date float =
  let time = Unix.gmtime float in
  Printf.sprintf "%04d%02d%02dT%02d:%02d:%02dZ"
    (time.Unix.tm_year+1900)
    (time.Unix.tm_mon+1)
    time.Unix.tm_mday
    time.Unix.tm_hour
    time.Unix.tm_min
    time.Unix.tm_sec

let task_list () =
	let all = Client.TASK.list dbg in
	List.iter
		(fun t ->
			Printf.printf "%-8s %-12s %-30s %s\n" t.Task.id (print_date t.Task.ctime) t.Task.dbg (t.Task.state |> Task.rpc_of_state |> Jsonrpc.to_string);
			List.iter
				(fun (name, state) ->
					Printf.printf "  |_ %-30s %s\n" name (state |> Task.rpc_of_state |> Jsonrpc.to_string)
				) t.Task.subtasks
		) all

let task_cancel id =
	Client.TASK.cancel dbg id

let debug_shutdown () =
	Client.DEBUG.shutdown dbg ()

let verbose_task t =
	let string_of_state = function
		| Task.Completed t -> Printf.sprintf "%.2f" t.Task.duration
		| Task.Failed x -> Printf.sprintf "Error: %s" (x |> Jsonrpc.to_string)
		| Task.Pending _ -> Printf.sprintf "Error: still pending" in
	let rows = List.map (fun (name, state) -> [ name;  string_of_state state ]) t.Task.subtasks in
	let rows = rows @ (List.map (fun (k, v) -> [ k; v ]) t.Task.debug_info) in
	Table.print rows;
	Printf.printf "\n";
	Printf.printf "Overall: %s\n" (string_of_state t.Task.state)


let old_main () =
	let args = Sys.argv |> Array.to_list |> List.tl in
	let verbose = List.mem "-v" args in
	let args = List.filter (fun x -> x <> "-v") args in
    (* Extract any -path X argument *)
	let extract args key =
		let result = ref None in
		let args =
			List.fold_left (fun (acc, foundit) x ->
				if foundit then (result := Some x; (acc, false))
				else if x = key then (acc, true)
				else (x :: acc, false)
			) ([], false) args |> fst |> List.rev in
		!result, args in
	let path, args = extract args "-path" in
	begin match path with
		| Some path -> Xenops_interface.set_sockets_dir path
		| None -> ()
	end;
	let task = success_task (if verbose then verbose_task else ignore_task) in
	match args with
		| [ "help" ] | [] ->
			usage ();
			exit 0
		| [ "add"; filename ] ->
			add filename
		| [ "remove"; id ] ->
			remove id
		| [ "export-metadata"; id; filename ] ->
			export_metadata id filename
		| [ "export-metadata-xm"; id; filename ] ->
			export_metadata_xm id filename
		| [ "import-metadata"; filename ] ->
			import_metadata filename
		| [ "pause"; id ] ->
			pause id |> task
		| [ "unpause"; id ] ->
			unpause id |> task
		| [ "shutdown"; id ] ->
			shutdown id None |> task
		| [ "shutdown"; id; timeout ] ->
			shutdown id (Some (float_of_string timeout)) |> task
		| [ "reboot"; id ] ->
			reboot id None |> task
		| [ "reboot"; id; timeout ] ->
			reboot id (Some (float_of_string timeout)) |> task
		| [ "suspend"; id; disk ] ->
			suspend id disk |> task
		| [ "resume"; id; disk ] ->
			resume id disk |> task
		| [ "migrate"; id; url ] ->
			migrate id url |> task
		| [ "vbd-list"; id ] ->
			vbd_list id
		| [ "console-list"; id ] ->
			console_list id
		| [ "pci-add"; id; idx; bdf ] ->
			pci_add id idx bdf
		| [ "pci-remove"; id; idx] ->
			pci_remove id idx
		| [ "pci-list"; id ] ->
			pci_list id
		| [ "cd-insert"; id; disk ] ->
			cd_insert id disk |> task
		| [ "cd-eject"; id ] ->
			cd_eject id |> task
		| [ "delay"; id; t ] ->
			delay id (float_of_string t)
		| [ "events-watch" ] ->
			events_watch None
		| [ "set-worker-pool-size"; size ] ->
			set_worker_pool_size (int_of_string size)
		| [ "diagnostics" ] ->
			diagnostics ()
		| [ "task-list" ] ->
			task_list ()
		| [ "task-cancel"; id ] ->
			task_cancel id
		| [ "shutdown" ] ->
			debug_shutdown ()
		| cmd :: _ ->
			Printf.fprintf stderr "Unrecognised command: %s\n" cmd;
			usage ();
			exit 1
