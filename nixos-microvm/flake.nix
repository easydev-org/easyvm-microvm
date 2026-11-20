{
  # A NIXOS MICROVM, BUILT BY CI AND VERIFIED LOCALLY.
  #
  # THE SAME SHAPE AS THE ALPINE AND DEBIAN MICROVMS: a kernel, an initramfs, and ONE FLAT ext4
  # qcow2 with no partition table. That is deliberate and it is the point of this file, because the
  # other two are built that way by `.github/alpine-rootfs.sh` and `.github/debian-rootfs.sh`, and a
  # third guest that needed its own disk layout would be a third thing to learn.
  #
  # WHY NOT `microvm.nix`'s STORE DISK, WHICH WAS TRIED FIRST.
  #
  # `microvm.nix` builds NixOS the container way: `/` is a tmpfs, the whole system is ONE READ-ONLY
  # erofs image mounted at /nix/store, and nothing is ever written. That works, and it was measured
  # booting here - but it has two costs that the other two guests do not pay:
  #
  #	1. THE GUEST CANNOT CHANGE. A read-only /nix/store means `nixos-rebuild` cannot build anything
  #	   inside the machine; new store paths have nowhere to go. Nix's own model survives this (a
  #	   rebuild ADDS immutable paths and repoints /run/current-system, it never edits an existing
  #	   one - which is why a read-only store is coherent at all), but the guest is a run-only
  #	   appliance rather than a system an operator can reconfigure.
  #
  #	2. THE ARTIFACT IS A THIRD DISK FORMAT. `microvm.storeDiskType` accepts only erofs and
  #	   squashfs, so the NixOS leg would ship an erofs `store.img` while its Alpine and Debian twins
  #	   ship ext4 `.qcow2` - two disk conventions in one family of three files.
  #
  # A FLAT ext4 ROOT PAYS NEITHER. `/nix/store` is an ordinary directory on the root filesystem, so
  # it is writable, `nixos-rebuild` works, and the disk qemu is handed is the same kind of object as
  # the other two.
  #
  # THE THREE THINGS THAT MAKE A `-kernel` BOOT WORK, NONE OF THEM NIXOS-SPECIFIC:
  #
  #	root=/dev/vda            the disk qemu attaches, named explicitly because there is no
  #	                         bootloader to pass it and no initrd to guess it from fstab alone
  #	VIRTIO_MMIO_CMDLINE_DEVICES
  #	                         the kernel option that lets a microvm FIND a virtio-over-MMIO disk
  #	                         from qemu's own command line. Nixpkgs sets it unconditionally
  #	                         (`common-config.nix`, and the workflow reads the built kernel's
  #	                         `.config` to prove it), so this file does not patch the kernel -
  #	                         patching would only stop the build from hitting cache.nixos.org.
  #	                         MEASURED, from each distribution's own config, because the four
  #	                         disagree and that is what the whole comparison rests on:
  #
  #	                           Alpine 3.21  VIRTIO_MMIO=y  CMDLINE_DEVICES=y
  #	                           NixOS 6.18   VIRTIO_MMIO=m  CMDLINE_DEVICES=y
  #	                           Debian 6.12  VIRTIO_MMIO=m  # CMDLINE_DEVICES is not set
  #	                           Void 6.12    VIRTIO_MMIO=m  (option absent)
  #
  #	                         Debian needs `acpi=on` to see the same disk; the engine states that
  #	                         on the machine type for every microvm, and adds `pci=off` so a kernel
  #	                         that assumes a PCI host bridge behind ACPI does not stop. NixOS needs
  #	                         neither, and is unaffected by both.
  #
  # IT IS A SEPARATE FLAKE because this repository has no other Nix, and a `flake.nix` at the root
  # would claim the whole tree.
  description = "NixOS guest for qemu's microvm machine type: kernel, initrd and a flat ext4 root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};



      guest = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ({ config, lib, pkgs, ... }: {
            # ---------------------------- THE MACHINE ----------------------------
            networking.hostName = "nixos-microvm";

            # THE GUEST HAS A NETWORK, WHICH IT DID NOT HAVE BEFORE THIS.
            #
            # MEASURED: this configuration declared a hostname and nothing else - no networkd, no DHCP
            # client, no resolver. `console.walk` only asserts on serial output, so an image with no
            # IP address passed every walkthrough it had; the moment anything inside the guest wants
            # a name (`nix`, `curl`, a package) it would fail with no clue why.
            #
            # A CONTAINER GETS ITS INTERFACE FROM ITS RUNTIME AND A VM DOES NOT. The tap is a bare
            # ethernet segment, so something inside has to ask for a lease - the same failure measured
            # on the Debian guest, where the bridge's ARP table showed `172.30.0.2 FAILED` while
            # dnsmasq ran and the tap was up.
            #
            # THE BRIDGE IS THE ONLY ADDRESS THE GUEST CAN REACH: `172.30.0.0/24` is its whole
            # network, and easyvm runs dnsmasq on `172.30.0.1` answering DNS and handing out the
            # lease. The cluster resolver (`172.18.0.10`) is outside that /24 with no route from
            # here, which is why `networking.nameservers` names the bridge rather than anything that
            # looks like a real DNS server.
            systemd.network.enable = true;
            networking.useDHCP = false;              # networkd does it, not dhcpcd
            systemd.network.networks."20-wired" = {
              matchConfig.Name = "en* eth*";
              networkConfig.DHCP = "yes";
              # `UseDNS=false` BECAUSE THE RESOLVER IS WRITTEN BELOW AND MUST HAVE ONE WRITER.
              # The lease's DNS option is the same 172.30.0.1, so this changes nothing today - it
              # keeps a second writer from appearing if the lease ever changes.
              dhcpV4Config.UseDNS = false;
            };
            # WRITTEN AS A REAL FILE rather than left to `resolvconf`, for the reason the Debian
            # image documents at length: a resolver that has to start before the file that names it
            # is a bootstrap that can deadlock, and `stub-resolv.conf` was exactly that.
            environment.etc."resolv.conf".text = ''
              # The bridge runs dnsmasq for this guest; it forwards to the cluster's resolver.
              nameserver 172.30.0.1
            '';

            # AND systemd-resolved IS TURNED OFF, BECAUSE IT WANTS THE SAME FILE.
            #
            # MEASURED, with `systemd.network.enable = true` and the file above, the evaluation of
            # this configuration stopped with
            #
            #	error: The option `environment.etc."resolv.conf".source' has conflicting definition values:
            #	- In .../modules/system/etc/etc.nix: <derivation etc-resolv.conf>
            #	- In .../modules/system/boot/resolved.nix: "/run/systemd/resolve/stub-resolv.conf"
            #
            # `networkd.nix` sets `services.resolved.enable = lib.mkDefault true`, so the two are in
            # conflict by design rather than by accident: resolved's whole job is to own
            # /etc/resolv.conf and point it at its own stub. `mkForce` is used rather than a plain
            # `false` so a future version of networkd that raises that priority does not turn this
            # back into a conflict - the guest's resolver is the bridge, and it is written one line
            # above.
            #
            # THE GUEST LOSES NOTHING BY THIS. Its only nameserver is 172.30.0.1, a fixed address
            # that never changes, so the caching and per-link routing resolved exists to provide have
            # nothing to do here.
            services.resolved.enable = lib.mkForce false;

            # AND `resolvconf`, WHICH IS THE SAME ARGUMENT ONE LAYER UP. MEASURED on the run that
            # first disabled resolved:
            #
            #	Failed assertions:
            #	- networking.resolvconf.enable is true but environment.etc."resolv.conf"
            #	  is also set. Set networking.resolvconf.enable = false if another
            #	  service manages /etc/resolv.conf.
            #
            # resolved.nix used to turn this off as a side effect of being enabled
            # (`networking.resolvconf.enable = false`), so disabling resolved handed the file back to
            # resolvconf and the assertion fired instead of the conflict. Both writers have to be
            # named, and this is the second one.
            networking.resolvconf.enable = lib.mkForce false;

            # NO BOOTLOADER. A microvm has no firmware to read a boot sector, so qemu is handed the
            # kernel and the initramfs directly with `-kernel`/`-initrd`. GRUB would be a disk
            # partition nothing ever reads.
            boot.loader.grub.enable = false;

            # ONE FILESYSTEM, NAMED BY THE DEVICE QEMU ATTACHES. There is no partition table on this
            # image, so there is no PARTUUID to name and no `/boot/efi` to satisfy - the second of
            # which is exactly what put the Debian guest into `You are in emergency mode` for 710
            # lines of console before it was found.
            fileSystems."/" = {
              device = "/dev/vda";
              fsType = "ext4";
              options = [ "rw" ];
            };

            # `root=/dev/vda` IS THE ONLY `root=`, AND THE REASON IS WORTH STATING.
            #
            # NixOS ADDS `root=fstab` OF ITS OWN ACCORD, and two `root=` arguments do not merge: the
            # last one on the command line wins. MEASURED on the built artifact, whose `kernel-args`
            # read
            #
            #	console=ttyS0 root=/dev/vda rootfstype=ext4 rw root=fstab loglevel=4 ...
            #
            # so the guest was told to infer its root from /etc/fstab rather than use the device it
            # was handed. On this image both reach /dev/vda and it booted anyway - which is exactly
            # why it would have gone unnoticed - but on a machine whose fstab is wrong the failure
            # would be a 30-second `Waiting for root` on a disk that plainly exists.
            # `init=` IS NOT OPTIONAL AND IS NOT DECORATION. It is the ONLY thing that tells NixOS'
            # initrd which closure to activate.
            #
            # MEASURED without it, on a guest whose ext4 root mounted perfectly:
            #
            #	EXT4-fs (vda): mounted filesystem ... r/w with ordered data mode
            #	[FAILED] Failed to start Find NixOS closure.
            #	[DEPEND] Dependency failed for Initrd Default Target.
            #	You are in emergency mode...
            #
            # `initrd-find-nixos-closure` reads `/proc/cmdline`, looks for `init=`, resolves it under
            # /sysroot and `chroot`s to its directory. With no `init=` it prints `No init= parameter
            # on the kernel command line` and refuses to hand over - so a disk that mounted and a
            # store that was present still never reach userspace. A bootloader would normally supply
            # this; a microvm has none, so it is supplied here.
            #
            # THE PATH CANNOT BE WRITTEN IN THE WALKTHROUGH because it is the store hash of this
            # build, and it changes on every rebuild. It is generated below into `kernel-args`, which
            # the walkthrough reads.
            #
            # `mkForce` REPLACES THE WHOLE LIST, and that is intended: NixOS' contribution here is
            # `root=fstab` plus `loglevel` and `lsm`, and dropping two cosmetic arguments is a much
            # smaller thing to get wrong than silently booting the wrong root.
            boot.kernelParams = lib.mkForce [
              "console=ttyS0"
              "root=/dev/vda"
              "rootfstype=ext4"
              "rw"
            ];

            # THE INITRAMFS HAS TO BE ABLE TO MOUNT THE ROOT BEFORE THERE IS A ROOT. `microvm.nix`
            # used to add these; without that module they are stated, because a stock NixOS initrd
            # carries the modules for the machine it was GENERATED on, not for a virtio-MMIO disk.
            boot.initrd.availableKernelModules = [
              "virtio" "virtio_ring" "virtio_mmio" "virtio_pci" "virtio_blk" "ext4"
            ];
            boot.initrd.kernelModules = [ "virtio_blk" "virtio_mmio" ];

            # ---------------------------- A CONSOLE ----------------------------
            # THE CONSOLE LOGS IN AS vmuser, AND THE SESSION BELONGS TO IT.
            #
            # THE REASON IS PIPEWIRE. Its packaged unit carries `ConditionUser=!root`, so a root
            # session cannot start it - MEASURED on KDE, where `systemctl --user start pipewire`
            # answered "inactive" and the journal said the condition was unmet. Every Wayland
            # desktop that captures or plays audio goes through PipeWire, so a root console cannot
            # run one.
            #
            # root KEEPS THE MACHINE: PID 1, the initramfs, resize2fs, sshd. The desktop is a user
            # process, which is what it is on every real system.
            users.users.root = {
              password = "";
              shell = pkgs.bashInteractive;
            };
            services.getty.autologinUser = "vmuser";

            # THE ACCOUNT AND THE DAEMON THE DRIVER LOGS IN AS.
            #
            # MEASURED: the daemon dials `vmuser` with password `admin` - `walk.File.SSHUser`
            # defaults to `vmuser`, `--password` defaults to `admin` - and this image had NO sshd and
            # no such account, so `/api/state` would answer `ssh_ready: false` forever on a guest
            # whose network was fine.
            #
            # `isNormalUser` GIVES IT A GROUP AND A HOME, which `useradd -m` would have done by hand
            # on the other images; NixOS asserts on the shapes it expects and this is the shape.
            users.users.vmuser = {
              isNormalUser = true;
              password = "admin";
              extraGroups = [ "wheel" ];
              shell = pkgs.bashInteractive;
            };
            # NOPASSWD BECAUSE THE DRIVER HAS NO TERMINAL TO ANSWER A SUDO PROMPT WITH.
            security.sudo.wheelNeedsPassword = false;

            # PASSWORD AUTH AND NO ROOT LOGIN: the console autologins vmuser, so a remote root
            # would be a second way in for no benefit.
            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = true;
                PermitRootLogin = "no";
              };
              # KEYS ARE GENERATED AT BUILD TIME, which is what `hostKeys` in the store means; a guest
              # that had to run `ssh-keygen` on first boot would wait on an entropy-less RNG.
              startWhenNeeded = false;
            };

            # ---------------------------- WHAT PROVES IT IS ALIVE ----------------------------
            # A SERVICE WHOSE BINARY LIVES ON THE ROOT FILESYSTEM. `echo` is a coreutils path in
            # /nix/store on /dev/vda, so this line cannot be printed unless the disk was found,
            # mounted, and the store inside it executed - which is what the artifact has to support.
            # Asserting on `login:` alone would prove less: agetty comes from the INITRAMFS, which
            # is a different file and mounts nothing.
            # GROW INTO THE DISK ONCE, BECAUSE THE IMAGE'S HEADROOM IS A GUESS.
            #
            # The disk has no partition table - the filesystem was written directly onto the image -
            # so this is `resize2fs` against the whole device with nothing to move. It is
            # `DefaultDependencies=false` and ordered after the rw remount because `resize2fs` will not
            # touch a filesystem that other units are already writing to.
            #
            # A STAMP MAKES IT ONCE-ONLY, and the failure is tolerated: a disk that was never enlarged
            # makes `resize2fs` fail, which is the normal case and not a reason to refuse to boot.
            systemd.services.growfs = {
              description = "grow the root filesystem into the disk it was given";
              wantedBy = [ "multi-user.target" ];
              after = [ "systemd-remount-fs.service" ];
              before = [ "local-fs.target" ];
              unitConfig.DefaultDependencies = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecCondition = "${pkgs.coreutils}/bin/test ! -f /var/lib/growfs-done";
                ExecStart = "${pkgs.bash}/bin/sh -c '${pkgs.e2fsprogs}/bin/resize2fs /dev/vda 2>/dev/null || true; touch /var/lib/growfs-done'";
              };
            };

            systemd.services.microvm-proof = {
              description = "announce that the root filesystem mounted and userspace is up";
              wantedBy = [ "multi-user.target" ];
              after = [ "local-fs.target" ];
              before = [ "getty.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/echo NIXOS-MICROVM-READY";
                StandardOutput = "journal+console";
              };
            };

            system.stateVersion = "25.11";
          })
        ];
      };
      # THE ROOT FILESYSTEM TREE, AS A TARBALL OF A COMPLETE SYSTEM.
      #
      # `make-system-tarball.nix` IS WHAT NIXOS' OWN NETBOOT IMAGES USE, and it is the one builder
      # here that needs NO VIRTUAL MACHINE. That matters: `make-disk-image.nix` looks like the
      # obvious choice - it even takes `fsType = "ext4"` and `partitionTableType = "none"` - but it
      # writes the filesystem inside `pkgs.vmTools.runInLinuxVM`, which declares the `kvm` system
      # feature. MEASURED on a host without KVM: `Required features: {kvm}`, and the build refuses
      # before producing anything. A GitHub runner has no /dev/kvm and neither does a container.
      #
      # `callPackage` RATHER THAN `import`: the builder takes nine arguments and a hand-written list
      # of them was wrong twice - `closureInfo` and `pixz` are both required and both invisible from
      # the file's own header. `callPackage` resolves them from nixpkgs and cannot miss one.
      #
      # What comes out is a tar of exactly what a NixOS root filesystem IS:
      #
      #	nix/store/<everything the system references>   the closure, copied whole
      #	init, kernel, kernel-modules, system, sw, etc   the top-level links `stage-2-init` needs
      #	nix-path-registration                          the database `nix-store --load-db` reads
      #
      # which is why the next step can unpack it and hand the result to `mke2fs -d`, the same two
      # lines `.github/alpine-rootfs.sh` and `.github/debian-rootfs.sh` use. NixOS stops being a
      # special case at exactly this point.
      rootfsTarballPath = (guest.pkgs.callPackage "${nixpkgs}/nixos/lib/make-system-tarball.nix" {
        # THE SYSTEM ITSELF IS THE ONLY "OBJECT". `symlink = "none"` means no extra top-level link:
        # the tarball's own `init`, `system` and `sw` are the ones a NixOS root filesystem has, and
        # `nix/store/nix-path-registration` is what lets the guest populate its Nix database on
        # first boot. This is the same shape NixOS' own netboot `kexecTarball` uses.
        storeContents = [
          {
            object = guest.config.system.build.toplevel;
            symlink = "none";
          }
        ];
        contents = [ ];
        fileName = "nixos-microvm";
        compressCommand = "gzip -9";
        compressionExtension = ".gz";
      }) + "/tarball/nixos-microvm.tar.gz";

    in {
      nixosConfigurations.nixos-microvm = guest;

      packages.${system} = {
        # THE DISK, IN THE SAME FORMAT THE OTHER TWO GUESTS USE, MADE THE SAME WAY.
        #
        # `tar -x` into a directory, then `mke2fs -d` writes that directory into an image with no
        # loop device and no VM - which is the only way inside a container, and is why this is a
        # `runCommandLocal` beside `rootfsTarball` rather than a call to `make-disk-image.nix`.
        #
        # `-O ^has_journal` IS NOT SET AND THE JOURNAL IS KEPT: the ext4 is genuinely writable, so
        # /nix/store is writable inside the guest and `nixos-rebuild` works there.
        rootfs = guest.pkgs.runCommandLocal "nixos-microvm-rootfs" {
          nativeBuildInputs = [ guest.pkgs.e2fsprogs guest.pkgs.qemu-utils ];
        } ''
          mkdir -p tree nix
          tar -xzf ${rootfsTarballPath} -C tree
          # `mke2fs -d` NEEDS THE DIRECTORY TO HOLD EVERYTHING, not a tarball. The size is read from
          # the tree and rounded up: a NixOS closure is hundreds of MiB and a fixed size either
          # wastes space or fails at the 400th megabyte with `No space left on device`.
          # 64 GiB, FIXED, AND THE SAME NUMBER EVERY OTHER VARIANT USES.
          #
          # qcow2 stores only clusters that were written, so a large virtual size costs nothing in
          # the file until somebody fills it - and `growfs` in the guest resizes the filesystem into
          # whatever the daemon hands it. That makes this a POLICY number rather than a build
          # artefact, and one number means "how big is a microvm disk" has an answer.
          size=65536
          truncate -s "''${size}M" rootfs.raw
          # `-N` IS NOT OPTIONAL AND `-i` WOULD NOT HAVE SAVED THIS.
          #
          # MEASURED, without it:
          #
          #	ext2fs_symlink: Could not allocate inode in ext2 filesystem while creating symlink
          #	                "pidof.1.gz"
          #	mke2fs: Could not allocate inode in ext2 filesystem while populating file system
          #
          # `mke2fs` picks an inode COUNT from the filesystem SIZE, and a NixOS store is the shape
          # that assumption gets wrong: a few hundred MiB holding tens of thousands of tiny files,
          # because every package is a directory of symlinks into other store paths. The default
          # runs out at the man pages. One inode per 4 KiB of TREE would be far more than needed;
          # the count below is derived from the tree itself, which is the only number that describes
          # this filesystem.
          # A STABLE NAME FOR THE SYSTEM, SO THE BOOT LINE CAN BE WRITTEN IN A FILE THAT DOES NOT
          # CHANGE. `/nixos-system` is a symlink to this build's toplevel, and the walkthrough's
          # `init=` names `/nixos-system/init` - which is the same instruction for every build,
          # forever, while the store hash behind it changes as it should.
          #
          # WITHOUT THIS the `init=` argument would have to be a literal store hash in a walkthrough,
          # which is stale the moment anything is rebuilt - and the failure is
          #
          #	[FAILED] Failed to start Find NixOS closure.
          #	You are in emergency mode...
          #
          # on a disk that mounted perfectly. MEASURED, that is exactly what happened.
          ln -s ${guest.config.system.build.toplevel} tree/nixos-system
          inodes=$(( $(find tree | wc -l) + 20000 ))
          mke2fs -q -F -t ext4 -N "$inodes" -d tree rootfs.raw
          qemu-img convert -f raw -O qcow2 -c rootfs.raw $out.raw
          mv $out.raw $out
        '';

        # THE THREE FILES, IN ONE DIRECTORY, WITH A STABLE NAME EACH.
        #
        # `microvm.kernel` no longer exists - `microvm.nix` is not in this configuration - so the
        # kernel comes from `config.system.build.kernel`, whose `out` is a directory holding
        # `bzImage` beside `System.map`. `nixpkgs.linux.target` is "bzImage" on x86_64, and it is
        # read rather than written so a future architecture does not silently copy the wrong file.
        default = pkgs.runCommandLocal "nixos-microvm-artifacts" { } ''
          mkdir -p $out
          ln -s ${guest.config.system.build.kernel.out}/${pkgs.linux.target} $out/kernel
          ln -s ${guest.config.system.build.initialRamdisk}/${guest.config.system.boot.loader.initrdFile} $out/initrd
          ln -s ${self.packages.${system}.rootfs} $out/rootfs.qcow2
          # THE KERNEL ARGUMENTS, AS A FILE, AND `init=` IS APPENDED HERE RATHER THAN IN THE MODULE.
          #
          # Two reasons it is not part of `boot.kernelParams`. It names a path inside the system it
          # belongs to, and the module cannot refer to the system it is defining - that is a
          # recursion. And it is the one
          # argument a person is most likely to "helpfully" retype into a walkthrough, where it would
          # be a stale store hash that fails on the next build in a way that reads as a missing init.
          #
          # It is the SAME list `microvm.nix` joins onto its own runner's command line, and the
          # initrd's `Find NixOS closure` unit reads it back out of /proc/cmdline.
          # `init=/nixos-system/init` IS THE STABLE NAME THE DISK CARRIES, not a store hash. The
          # image's own root holds `/nixos-system` as a symlink to this build's toplevel, so this
          # line is identical for every build and still points at the right system.
          printf '%s init=/nixos-system/init' \
            '${nixpkgs.lib.concatStringsSep " " guest.config.boot.kernelParams}' > $out/kernel-args
        '';

        # THE KERNEL'S `.config`, AS ITS OWN OUTPUT, so CI can read it instead of trusting a comment.
        # `passthru.configfile` is the derivation nixpkgs builds from the merged Kconfig; it is cheap
        # and cacheable on its own, and it is the only honest way to answer "is
        # VIRTIO_MMIO_CMDLINE_DEVICES really y in the kernel we are about to ship".
        kernelConfig = guest.config.boot.kernelPackages.kernel.passthru.configfile;

        # THE EXACT COMMAND THAT BOOTS THIS ARTIFACT, generated from the configuration rather than
        # typed out beside it, so the two cannot drift.
        bootCommand = pkgs.writeText "boot-command.txt" ''
          # Boot the NixOS microvm from three files. Nothing else is needed: there is no firmware and
          # no bootloader, and the disk is one flat ext4 filesystem.
          qemu-system-x86_64 \
            -M microvm,accel=kvm:tcg,rtc=on,pic=on,acpi=on,pcie=off,graphics=off \
            -cpu host -m 1536 -smp 2 \
            -kernel kernel -initrd initrd \
            -drive file=rootfs.qcow2,if=none,id=store,format=qcow2 \
            -device virtio-blk-device,drive=store \
            -device virtio-rng-device \
            -nodefaults -no-reboot -nographic \
            -append "pci=off $(cat kernel-args)"

          # `-nographic` ALREADY PUTS THE SERIAL CONSOLE ON YOUR TERMINAL. Do not add `-serial
          # file:...` beside it: -nographic redirects the port and wins, so the file stays empty and
          # the output appears on the console instead. MEASURED. If a log file is wanted, replace
          # `-nographic` with `-display none -serial file:LOG`.
          #
          # `pci=off` IS NOT OPTIONAL. The machine gets `acpi=on` because Debian needs an ACPI
          # namespace to find its MMIO disk, and a kernel that sees an ACPI root with no PCI bus
          # stops at `PCI: Fatal: No config space access function found`. `pci=off` states the truth
          # about this machine and the boot continues - MEASURED, this guest printed that warning
          # and then reached `NIXOS-MICROVM-READY` and `login:`.
          #
          # WHAT A CORRECT BOOT LOOKS LIKE: these three lines, in this order.
          #
          #   EXT4-fs (vda): mounted filesystem
          #   echo[476]: NIXOS-MICROVM-READY
          #   nixos-microvm login: root (automatic login)
        '';
      };
    };
}
