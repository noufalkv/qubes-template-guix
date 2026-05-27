;; SPDX-License-Identifier: GPL-3.0-or-later
;; Native GNU Guix System configuration for Qubes TemplateVM images.
;;
;; This is intentionally self-contained.  Build scripts use the same file
;; for normal and minimal variants by setting QUBES_GUIX_TEMPLATE_VARIANT.

(use-modules
  ((guix licenses) #:prefix license:)
  (guix build-system copy)
  (guix build-system gnu)
  (guix build-system trivial)
  (guix gexp)
  (guix git-download)
  (guix modules)
  (guix packages)
  (guix records)
  (guix utils)
  (gnu)
  (gnu bootloader)
  (gnu packages admin)
  (gnu packages autotools)
  (gnu packages base)
  (gnu packages bash)
  (gnu packages benchmark)
  (gnu packages certs)
  (gnu packages commencement)
  (gnu packages compression)
  (gnu packages curl)
  (gnu packages dns)
  (gnu packages elf)
  (gnu packages freedesktop)
  (gnu packages gawk)
  (gnu packages glib)
  (gnu packages gnome)
  (gnu packages gtk)
  (gnu packages guile)
  (gnu packages haskell-xyz)
  (gnu packages icu4c)
  (gnu packages image)
  (gnu packages libffi)
  (gnu packages libunistring)
  (gnu packages linux)
  (gnu packages networking)
  (gnu packages nss)
  (gnu packages package-management)
  (gnu packages pciutils)
  (gnu packages pkg-config)
  (gnu packages pulseaudio)
  (gnu packages python)
  (gnu packages python-build)
  (gnu packages python-xyz)
  (gnu packages rpm)
  (gnu packages version-control)
  (gnu packages virtualization)
  (gnu packages xfce)
  (gnu packages xdisorg)
  (gnu packages xorg)
  (gnu services)
  (gnu services base)
  (gnu services dbus)
  (gnu services shepherd)
  (gnu services sysctl)
  (gnu system nss)
  (gnu system pam)
  (gnu system privilege)
  (ice-9 match)
  (ice-9 rdelim)
  (ice-9 textual-ports)
  (srfi srfi-1)
  (srfi srfi-13))

(define %qvm-template-repo-query-guix
  (plain-file
   "qvm-template-repo-query-guix"
   (string-append
   "#!/run/current-system/profile/bin/python3\n"
   "# SPDX-License-Identifier: GPL-2.0-or-later\n"
   "\"\"\"Guix fallback for Qubes template repository qrexec helpers.\n"
   "\n"
   "The stock qvm-template-repo-query helper delegates rpm-md repository access to\n"
   "DNF.  Native Guix System templates do not ship DNF, but qvm-template only needs\n"
   "template repo query rows and raw RPM download bytes from the UpdateVM.  This\n"
   "helper implements that narrow rpm-md path with Python, curl, and zstd.\n"
   "\"\"\"\n"
   "\n"
   "import configparser\n"
   "import fnmatch\n"
   "import gzip\n"
   "import subprocess\n"
   "import sys\n"
   "import urllib.parse\n"
   "import xml.etree.ElementTree as ET\n"
   "\n"
   "\n"
   "REPO_NS = \"http://linux.duke.edu/metadata/repo\"\n"
   "COMMON_NS = \"http://linux.duke.edu/metadata/common\"\n"
   "RPM_NS = \"http://linux.duke.edu/metadata/rpm\"\n"
   "PACKAGE_PREFIX = \"qubes-template-\"\n"
   "\n"
   "\n"
   "def error(message):\n"
   "    print(f\"ERROR: {message}\", file=sys.stderr)\n"
   "    return 1\n"
   "\n"
   "\n"
   "def curl_bytes(url):\n"
   "    return subprocess.check_output(\n"
   "        [\"curl\", \"--fail\", \"--silent\", \"--show-error\", \"--location\", url]\n"
   "    )\n"
   "\n"
   "\n"
   "def curl_to_stdout(url):\n"
   "    return subprocess.call(\n"
   "        [\"curl\", \"--fail\", \"--silent\", \"--show-error\", \"--location\",\n"
   "         \"-o\", \"-\", url]\n"
   "    )\n"
   "\n"
   "\n"
   "def expand_repo_value(value, releasever):\n"
   "    return (\n"
   "        value.replace(\"${releasever}\", releasever)\n"
   "        .replace(\"$releasever\", releasever)\n"
   "        .replace(\"${basearch}\", \"x86_64\")\n"
   "        .replace(\"$basearch\", \"x86_64\")\n"
   "    )\n"
   "\n"
   "\n"
   "def parse_payload(stdin_text):\n"
   "    options = []\n"
   "    spec = \"*\"\n"
   "    repo_lines = []\n"
   "    in_repo_config = False\n"
   "\n"
   "    for line in stdin_text.splitlines():\n"
   "        if in_repo_config:\n"
   "            repo_lines.append(line)\n"
   "            continue\n"
   "        if line == \"---\":\n"
   "            in_repo_config = True\n"
   "        elif line.startswith(\"--enablerepo=\"):\n"
   "            options.append((\"enable\", line.split(\"=\", 1)[1]))\n"
   "        elif line.startswith(\"--disablerepo=\"):\n"
   "            options.append((\"disable\", line.split(\"=\", 1)[1]))\n"
   "        elif line.startswith(\"--repoid=\"):\n"
   "            options.append((\"repoid\", line.split(\"=\", 1)[1]))\n"
   "        elif line.startswith(\"--releasever=\"):\n"
   "            options.append((\"releasever\", line.split(\"=\", 1)[1]))\n"
   "        elif line == \"--refresh\":\n"
   "            pass\n"
   "        elif line:\n"
   "            spec = line\n"
   "\n"
   "    return options, spec, \"\\n\".join(repo_lines) + \"\\n\"\n"
   "\n"
   "\n"
   "def parse_repo_config(repo_text):\n"
   "    config = configparser.ConfigParser(interpolation=None, strict=False)\n"
   "    config.read_string(repo_text)\n"
   "    return config\n"
   "\n"
   "\n"
   "def repo_enabled(section, config, options):\n"
   "    enabled = config.get(section, \"enabled\", fallback=\"1\").strip().lower()\n"
   "    is_enabled = enabled not in (\"0\", \"false\", \"no\", \"off\")\n"
   "    repoids = []\n"
   "\n"
   "    for op, pattern in options:\n"
   "        if op == \"repoid\":\n"
   "            repoids.append(pattern)\n"
   "        elif op in (\"enable\", \"disable\") and fnmatch.fnmatchcase(section, pattern):\n"
   "            is_enabled = op == \"enable\"\n"
   "\n"
   "    if repoids and not any(fnmatch.fnmatchcase(section, pat) for pat in repoids):\n"
   "        is_enabled = False\n"
   "\n"
   "    return is_enabled\n"
   "\n"
   "\n"
   "def repo_baseurls(section, config, releasever):\n"
   "    baseurls = []\n"
   "\n"
   "    if config.has_option(section, \"baseurl\"):\n"
   "        raw = expand_repo_value(config.get(section, \"baseurl\"), releasever)\n"
   "        baseurls.extend(item for item in raw.split() if item)\n"
   "\n"
   "    if not baseurls and config.has_option(section, \"metalink\"):\n"
   "        metalink = expand_repo_value(config.get(section, \"metalink\"), releasever)\n"
   "        suffix = \"/repodata/repomd.xml.metalink\"\n"
   "        if metalink.endswith(suffix):\n"
   "            baseurls.append(metalink[: -len(suffix)])\n"
   "        else:\n"
   "            try:\n"
   "                root = ET.fromstring(curl_bytes(metalink))\n"
   "                for element in root.iter():\n"
   "                    if element.tag.rsplit(\"}\", 1)[-1] != \"url\" or not element.text:\n"
   "                        continue\n"
   "                    url = element.text.strip()\n"
   "                    marker = \"/repodata/repomd.xml\"\n"
   "                    if marker in url:\n"
   "                        baseurls.append(url.split(marker, 1)[0])\n"
   "            except (ET.ParseError, subprocess.CalledProcessError):\n"
   "                pass\n"
   "\n"
   "    return baseurls\n"
   "\n"
   "\n"
   "def primary_metadata_url(baseurl):\n"
   "    repomd_url = urllib.parse.urljoin(baseurl.rstrip(\"/\") + \"/\",\n"
   "                                      \"repodata/repomd.xml\")\n"
   "    root = ET.fromstring(curl_bytes(repomd_url))\n"
   "    for data in root.findall(f\"{{{REPO_NS}}}data\"):\n"
   "        if data.attrib.get(\"type\") != \"primary\":\n"
   "            continue\n"
   "        location = data.find(f\"{{{REPO_NS}}}location\")\n"
   "        if location is None:\n"
   "            continue\n"
   "        href = location.attrib.get(\"href\")\n"
   "        if href:\n"
   "            return urllib.parse.urljoin(baseurl.rstrip(\"/\") + \"/\", href)\n"
   "    raise RuntimeError(f\"primary metadata not found in {repomd_url}\")\n"
   "\n"
   "\n"
   "def decompress_metadata(url, data):\n"
   "    if url.endswith(\".zst\"):\n"
   "        return subprocess.check_output([\"zstd\", \"-dc\"], input=data)\n"
   "    if url.endswith(\".gz\"):\n"
   "        return gzip.decompress(data)\n"
   "    return data\n"
   "\n"
   "\n"
   "def child_text(element, namespace, name, default=\"\"):\n"
   "    child = element.find(f\"{{{namespace}}}{name}\")\n"
   "    if child is None or child.text is None:\n"
   "        return default\n"
   "    return child.text\n"
   "\n"
   "\n"
   "def clean_field(value):\n"
   "    return \" \".join((value or \"\").replace(\"|\", \" \").split())\n"
   "\n"
   "\n"
   "def parse_packages(repoid, baseurl):\n"
   "    primary_url = primary_metadata_url(baseurl)\n"
   "    metadata = decompress_metadata(primary_url, curl_bytes(primary_url))\n"
   "    root = ET.fromstring(metadata)\n"
   "    packages = []\n"
   "\n"
   "    for package in root.findall(f\"{{{COMMON_NS}}}package\"):\n"
   "        name = child_text(package, COMMON_NS, \"name\")\n"
   "        if not name.startswith(PACKAGE_PREFIX):\n"
   "            continue\n"
   "\n"
   "        version = package.find(f\"{{{COMMON_NS}}}version\")\n"
   "        size = package.find(f\"{{{COMMON_NS}}}size\")\n"
   "        location = package.find(f\"{{{COMMON_NS}}}location\")\n"
   "        build_time = package.find(f\"{{{COMMON_NS}}}time\")\n"
   "        fmt = package.find(f\"{{{COMMON_NS}}}format\")\n"
   "        if version is None or size is None or location is None:\n"
   "            continue\n"
   "\n"
   "        license_text = \"\"\n"
   "        if fmt is not None:\n"
   "            license_text = child_text(fmt, RPM_NS, \"license\", \"GPLv3+\")\n"
   "\n"
   "        href = location.attrib.get(\"href\", \"\")\n"
   "        packages.append({\n"
   "            \"name\": name,\n"
   "            \"epoch\": version.attrib.get(\"epoch\", \"0\") or \"0\",\n"
   "            \"version\": version.attrib.get(\"ver\", \"\"),\n"
   "            \"release\": version.attrib.get(\"rel\", \"\"),\n"
   "            \"repoid\": repoid,\n"
   "            \"size\": size.attrib.get(\"package\", \"0\"),\n"
   "            \"buildtime\": (build_time.attrib.get(\"build\", \"0\")\n"
   "                          if build_time is not None else \"0\"),\n"
   "            \"license\": license_text or \"GPLv3+\",\n"
   "            \"url\": child_text(package, COMMON_NS, \"url\",\n"
   "                              \"https://www.qubes-os.org\"),\n"
   "            \"summary\": child_text(package, COMMON_NS, \"summary\"),\n"
   "            \"description\": child_text(package, COMMON_NS, \"description\"),\n"
   "            \"download_url\": urllib.parse.urljoin(baseurl.rstrip(\"/\") + \"/\", href),\n"
   "        })\n"
   "\n"
   "    return packages\n"
   "\n"
   "\n"
   "def package_targets(package):\n"
   "    name = package[\"name\"]\n"
   "    epoch = package[\"epoch\"]\n"
   "    version = package[\"version\"]\n"
   "    release = package[\"release\"]\n"
   "    targets = [\n"
   "        f\"{name}-{epoch}:{version}-{release}\",\n"
   "        name,\n"
   "        f\"{name}-{epoch}:{version}\",\n"
   "    ]\n"
   "    if epoch == \"0\":\n"
   "        targets.extend([\n"
   "            f\"{name}-{version}-{release}\",\n"
   "            f\"{name}-{version}\",\n"
   "        ])\n"
   "    return targets\n"
   "\n"
   "\n"
   "def package_matches(package, spec):\n"
   "    return spec in (\"\", \"*\") or any(\n"
   "        fnmatch.fnmatchcase(target, spec) for target in package_targets(package)\n"
   "    )\n"
   "\n"
   "\n"
   "def iter_enabled_packages(config, options):\n"
   "    releasever = \"4.3\"\n"
   "    for op, value in options:\n"
   "        if op == \"releasever\":\n"
   "            releasever = value\n"
   "\n"
   "    for section in config.sections():\n"
   "        if not repo_enabled(section, config, options):\n"
   "            continue\n"
   "        for baseurl in repo_baseurls(section, config, releasever):\n"
   "            try:\n"
   "                yield from parse_packages(section, baseurl)\n"
   "                break\n"
   "            except (ET.ParseError, RuntimeError, subprocess.CalledProcessError) as exc:\n"
   "                print(f\"WARNING: failed to query {section} at {baseurl}: {exc}\",\n"
   "                      file=sys.stderr)\n"
   "\n"
   "\n"
   "def query(config, options, spec):\n"
   "    for package in iter_enabled_packages(config, options):\n"
   "        if not package_matches(package, spec):\n"
   "            continue\n"
   "        fields = [\n"
   "            package[\"name\"],\n"
   "            package[\"epoch\"],\n"
   "            package[\"version\"],\n"
   "            package[\"release\"],\n"
   "            package[\"repoid\"],\n"
   "            package[\"size\"],\n"
   "            package[\"buildtime\"],\n"
   "            package[\"license\"],\n"
   "            package[\"url\"],\n"
   "            package[\"summary\"],\n"
   "            package[\"description\"],\n"
   "        ]\n"
   "        print(\"|\".join(clean_field(field) for field in fields) + \"|\")\n"
   "    return 0\n"
   "\n"
   "\n"
   "def download(config, options, spec):\n"
   "    for package in iter_enabled_packages(config, options):\n"
   "        if package_matches(package, spec):\n"
   "            return curl_to_stdout(package[\"download_url\"])\n"
   "    return error(f\"template package not found: {spec}\")\n"
   "\n"
   "\n"
   "def main():\n"
   "    if len(sys.argv) != 2 or sys.argv[1] not in (\"query\", \"download\"):\n"
   "        return error(\"usage: qvm-template-repo-query-guix query|download\")\n"
   "\n"
   "    options, spec, repo_text = parse_payload(sys.stdin.read())\n"
   "    try:\n"
   "        config = parse_repo_config(repo_text)\n"
   "    except configparser.Error as exc:\n"
   "        return error(f\"failed to parse template repo config: {exc}\")\n"
   "\n"
   "    if sys.argv[1] == \"query\":\n"
   "        return query(config, options, spec)\n"
   "    return download(config, options, spec)\n"
   "\n"
   "\n"
   "if __name__ == \"__main__\":\n"
   "    raise SystemExit(main())\n"
   )))

;;; Qubes VM package definitions
;; SPDX-License-Identifier: GPL-3.0-or-later


(define %qubes-source-components
  '(("qubes-core-vchan-xen" "v4.2.8"
     "a1337c282ffefcfc13a570683c57bc04813038db"
     "0nb5ky69w0v6xy7dkriagyi8fa2zpq2dnibr90pkf7asi0cib77j")
    ("qubes-linux-utils" "v4.3.17"
     "ee1e61f487f57d6b5d3ff96dbd8d6b50bd474656"
     "19q2i9gz4v585gw9mpmn1pw1zmykr3awg30rzm4vbfnv5i0czh56")
    ("qubes-core-qubesdb" "v4.3.2"
     "7d294b2ab922708b552fb2715f6a0333fbc52fcd"
     "1kal2lf4frjk083qd0ql5m8znbzn77pndxhclkl0pbc7v5ycrfyd")
    ("qubes-core-qrexec" "v4.3.12"
     "cc801b8f630a65dfb2855b829bfc070f6e82f26a"
     "1lbz435sjs3d7pc9ymnwxqi14sc83xdnny5pzwp8c580rraysvd4")
    ("qubes-core-agent-linux" "v4.3.43"
     "0f20e0b74cfca0fcf42c3658099a1cedd26bde60"
     "0dlf2rxvi2yjzv59a1pjy98d4cm8ad7cg08g9d8392ly5l0sw5gn")
    ("qubes-gui-common" "v4.3.1"
     "66b879e36d6cd2a01271fc8d4c2c0f3be85d0029"
     "1ilr2wximl82y05f9dha69pjwhks2c73cfh08yxpnbdg5yspcc24")
    ("qubes-gui-agent-linux" "v4.3.16"
     "bd8c395df20e64845ac4b3324552aebca32fea96"
     "1pp5s1ghg9hha9rlc7v3lscbvpfyhl9zpjknci9nq5h1630a8hck")))

(define (qubes-source-field component index)
  (let ((entry (assoc component %qubes-source-components)))
    (unless entry
      (error "unknown Qubes source component" component))
    (list-ref entry index)))

(define (qubes-release-version component)
  (let ((tag (qubes-source-field component 1)))
    (if (and (> (string-length tag) 0)
             (char=? (string-ref tag 0) #\v))
        (substring tag 1)
        tag)))

(define (qubes-release-source component)
  (origin
    (method git-fetch)
    (uri (git-reference
          (url (string-append "https://github.com/QubesOS/" component ".git"))
          (commit (qubes-source-field component 2))))
    (file-name (string-append component "-" (qubes-source-field component 1)
                              "-checkout"))
    (sha256 (base32 (qubes-source-field component 3)))))

(define qubes-dom0-kernel
  (package
    (name "qubes-dom0-kernel")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder
      #~(begin
          (mkdir #$output)
          (mkdir (string-append #$output "/lib"))
          (mkdir (string-append #$output "/lib/modules"))
          (call-with-output-file (string-append #$output "/bzImage")
            (lambda (port)
              (display "Qubes dom0 supplies the VM kernel.\n" port))))))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Placeholder kernel for Qubes TemplateVM images")
    (description "Placeholder kernel package used by native Qubes TemplateVM
images.  Qubes dom0 supplies the actual VM kernel at boot time, so the template
root image does not need a guest kernel package.")
    (license license:gpl2+)))

(define xen-vchan-libs
  (package
    (name "xen-vchan-libs")
    (version (package-version xen))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils) (ice-9 ftw) (ice-9 popen)
                  (ice-9 rdelim) (ice-9 regex))
      #:builder
      #~(begin
          (use-modules (guix build utils)
                       (ice-9 ftw)
                       (ice-9 popen)
                       (ice-9 rdelim)
                       (ice-9 regex))

          (define prefixes
            '("libxenvchan" "libxenctrl" "libxenstore" "libxentoollog"
              "libxengnttab" "libxenevtchn" "libxencall"
              "libxenforeignmemory" "libxendevicemodel" "libxentoolcore"))

          (define (string-prefix? prefix value)
            (let ((prefix-length (string-length prefix)))
              (and (>= (string-length value) prefix-length)
                   (string=? prefix (substring value 0 prefix-length)))))

          (define (wanted-library? entry)
            (and (string-match "\\.so" entry)
                 (let loop ((prefixes prefixes))
                   (and (pair? prefixes)
                        (or (string-prefix? (car prefixes) entry)
                            (loop (cdr prefixes)))))))

          (define (copy-entry source destination)
            (let ((stat (lstat source)))
              (case (stat:type stat)
                ((symlink) (symlink (readlink source) destination))
                ((regular) (copy-file source destination)))))

          (define (command-line-output . args)
            (let* ((port (apply open-pipe* OPEN_READ args))
                   (line (read-line port)))
              (close-pipe port)
              (if (eof-object? line) "" line)))

          (define (replace-substring value needle replacement)
            (let ((needle-length (string-length needle)))
              (let loop ((start 0) (pieces '()))
                (let ((index (string-contains value needle start)))
                  (if index
                      (loop (+ index needle-length)
                            (cons replacement
                                  (cons (substring value start index) pieces)))
                      (apply string-append
                             (reverse
                              (cons (substring value start) pieces))))))))

          (let ((source-lib (string-append #$xen "/lib"))
                (out-lib (string-append #$output "/lib"))
                (patchelf (string-append #$patchelf "/bin/patchelf")))
            (mkdir-p out-lib)
            (for-each
             (lambda (entry)
               (when (wanted-library? entry)
                 (copy-entry (string-append source-lib "/" entry)
                             (string-append out-lib "/" entry))))
             (scandir source-lib))
            ;; Guix's Xen libraries carry an RPATH back to the full Xen output,
            ;; which would retain Xen tools, QEMU, firmware, and OVMF in the
            ;; template.  Rewrite copied shared objects to resolve within this
            ;; tiny library subset while preserving libc/libgcc paths.
            (for-each
             (lambda (entry)
               (let ((file (string-append out-lib "/" entry)))
                 (when (and (wanted-library? entry)
                            (eq? (stat:type (lstat file)) 'regular))
                   (let* ((rpath (command-line-output
                                  patchelf "--print-rpath" file))
                          (new-rpath
                           (replace-substring rpath source-lib out-lib)))
                     (when (and (not (string-null? rpath))
                                (not (string=? rpath new-rpath)))
                       (chmod file #o644)
                       (invoke patchelf "--set-rpath" new-rpath file)
                       (chmod file #o555))))))
             (scandir out-lib))
            #t))))
    (native-inputs (list patchelf))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Small Xen vchan runtime library subset")
    (description "Runtime subset of Xen libraries needed by the Qubes VM-side
vchan and qrexec components, without Xen hypervisor tools, QEMU, or firmware.")
    (license license:gpl2+)))

(define xen-network-hotplug-tools
  (package
    (name "xen-network-hotplug-tools")
    (version (package-version xen))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out-bin (string-append #$output "/bin"))
                 (out-scripts (string-append #$output "/etc/xen/scripts"))
                 (xen-scripts (string-append #$xen "/etc/xen/scripts"))
                 (rpath (string-append #$xen-vchan-libs "/lib")))
            (mkdir-p out-bin)
            (mkdir-p out-scripts)
            (for-each
             (lambda (tool)
               (let ((target (string-append out-bin "/" tool)))
                 (copy-file (string-append #$xen "/bin/" tool) target)
                 (chmod target #o755)
                 (invoke (string-append #$patchelf "/bin/patchelf")
                         "--set-rpath" rpath target)))
             '("xenstore-read" "xenstore-write"))
            (for-each
             (lambda (script)
               (let ((target (string-append out-scripts "/" script)))
                 (copy-file (string-append xen-scripts "/" script) target)
                 (chmod target #o755)
                 (substitute* target
                   ((#$xen) #$output))))
             '("hotplugpath.sh"
               "locking.sh"
               "logging.sh"
               "vif-common.sh"
               "xen-hotplug-common.sh"
               "xen-network-common.sh"
               "xen-script-common.sh"))))))
    (native-inputs (list patchelf))
    (inputs (list xen-vchan-libs))
    (home-page "https://xenproject.org/")
    (synopsis "Small Xen network hotplug subset for Qubes NetVMs")
    (description "A small package containing the XenStore tools and Xen network
hotplug helper scripts required by Qubes' VM-side vif-route-qubes backend
script, without adding the full Xen tool stack to native Qubes Guix templates.")
    (license license:gpl2)))

(define xenstore-read-tool
  xen-network-hotplug-tools)

(define qubes-libvchan-xen
  (package
    (name "qubes-libvchan-xen")
    (version (qubes-release-version "qubes-core-vchan-xen"))
    (source (qubes-release-source "qubes-core-vchan-xen"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; This upstream makefile builds and installs the VM-side vchan library;
      ;; it does not provide a test target.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make" "all"
                      "CC=gcc"
                      (string-append "PREFIX=" #$output)
                      (string-append "LIBDIR=" #$output "/lib")
                      (string-append "INCLUDEDIR=" #$output "/include")
                      (string-append "LDFLAGS=-L" #$xen-vchan-libs "/lib "
                                     "-Wl,-rpath=" #$xen-vchan-libs "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "install"
                      "DESTDIR="
                      (string-append "PREFIX=" #$output)
                      (string-append "LIBDIR=" #$output "/lib")
                      (string-append "INCLUDEDIR=" #$output "/include")))))))
    (native-inputs (list pkg-config xen))
    (inputs (list xen-vchan-libs))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes Xen vchan library")
    (description "VM-side Xen vchan support used by Qubes agents.")
    (license license:gpl2+)))

(define qubes-linux-utils-qrexec
  (package
    (name "qubes-linux-utils-qrexec")
    (version (qubes-release-version "qubes-linux-utils"))
    (source (qubes-release-source "qubes-linux-utils"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; This upstream subdirectory builds and installs the qrexec file-copy
      ;; support library; it does not provide a test target.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make" "-C" "qrexec-lib" "all"
                      "CC=gcc"
                      "NO_REBUILD_TABLE=1"
                      (string-append
                       "LDFLAGS=-Wl,--no-undefined,--as-needed,-Bsymbolic -L . -Wl,-rpath="
                       #$output "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "-C" "qrexec-lib" "install"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "INCLUDEDIR=/include"))))))
    (native-inputs (list pkg-config))
    (inputs (list icu4c))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes qrexec file-copy support libraries")
    (description "Qubes RPC file-copy and pure utility libraries used by VM-side agents.")
    (license license:gpl2+)))

(define qubes-vm-utils
  (package
    (name "qubes-vm-utils")
    (version (qubes-release-version "qubes-linux-utils"))
    (source (qubes-release-source "qubes-linux-utils"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The qmemman subdirectory only builds the meminfo-writer program and
      ;; installs its systemd units; it does not provide a test target.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make" "-C" "qmemman" "all"
                      "CC=gcc"
                      (string-append "CFLAGS=-Wall -Wextra -Werror -g -O3 "
                                     "-DUSE_XENSTORE_H -I" #$xen "/include")
                      (string-append "LDFLAGS=-L" #$xen "/lib "
                                     "-Wl,-rpath=" #$xen "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "-C" "qmemman" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin"))))))
    (inputs (list xen))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes VM utility programs")
    (description "VM-side Qubes utility programs, including the memory
information reporter used by Qubes memory ballooning.")
    (license license:gpl2+)))

(define qubesdb-vm
  (package
    (name "qubesdb-vm")
    (version (qubes-release-version "qubes-core-qubesdb"))
    (source (qubes-release-source "qubes-core-qubesdb"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The daemon tests expect a live QubesDB/Xen VM environment; this
      ;; package build installs the VM-side daemon, tools, and bindings.
      #:tests? #f
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 regex))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'run-vm-daemon-in-foreground
            (lambda _
              ;; Shepherd tracks the process it starts.  The upstream daemon
              ;; forks when built without systemd support, which leaves
              ;; duplicate VM-side QubesDB daemons racing for the same vchan.
              (substitute* "daemon/db-daemon.c"
                (("    if \\(1\\) \\{")
                 "    if (0) {"))))
          (replace 'build
            (lambda _
              (let ((rpath (string-append "-Wl,-rpath=" #$output "/lib")))
                (invoke "make" "all" "SYSTEMD=0" "CC=gcc"
                        (string-append "LDFLAGS=" rpath)
                        (string-append "APPEND_LDFLAGS=" rpath)))))
          (replace 'install
            (lambda _
              (invoke "make" "-C" "daemon" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin")
              (invoke "make" "-C" "client" "install"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "BINDIR=/bin")
              ;; The upstream client installs hard-linked applets that infer
              ;; the command from argv[0].  In a Guix profile argv[0] is often
              ;; a store/profile path rather than /usr/bin/qubesdb-read, which
              ;; makes the applet print usage and exit 0.  Install explicit
              ;; wrappers so both Qubes scripts and native services get stable
              ;; read/write/list behavior.
              (let ((qubesdb-cmd (string-append #$output "/bin/qubesdb-cmd")))
                (for-each
                 (lambda (entry)
                   (let ((path (string-append #$output "/bin/" (car entry)))
                         (command (cadr entry)))
                     (when (file-exists? path)
                       (delete-file path))
                     (call-with-output-file path
                       (lambda (port)
                         (format port
                                 "#!~a~%exec ~a -c ~a \"$@\"~%"
                                 #$(file-append bash-minimal "/bin/sh")
                                 qubesdb-cmd
                                 command)))
                     (chmod path #o755)))
                 '(("qubesdb-read" "read")
                   ("qubesdb-write" "write")
                   ("qubesdb-rm" "rm")
                   ("qubesdb-multiread" "multiread")
                   ("qubesdb-list" "list")
                   ("qubesdb-watch" "watch"))))
              (let* ((extensions
                      (find-files "python/build" "^qubesdb.*\\.so$"))
                     (first-extension
                      (and (pair? extensions) (car extensions)))
                     (python-tag
                      (and first-extension
                           (string-match "\\.cpython-([0-9])([0-9]+)"
                                         (basename first-extension)))))
                (unless python-tag
                  (error "no built qubesdb Python extension found"))
                (let ((site
                       (string-append #$output
                                      "/lib/python"
                                      (match:substring python-tag 1)
                                      "."
                                      (match:substring python-tag 2)
                                      "/site-packages")))
                  (mkdir-p site)
                  (for-each
                   (lambda (extension)
                     (copy-file extension
                                (string-append site "/"
                                               (basename extension))))
                   extensions)))
              (invoke "make" "-C" "include" "install"
                      (string-append "DESTDIR=" #$output)
                      "INCLUDEDIR=/include"))))))
    (native-inputs (list pkg-config python-wrapper python-setuptools))
    (inputs (list bash-minimal qubes-libvchan-xen))
    (home-page "https://www.qubes-os.org/")
    (synopsis "QubesDB VM daemon and client tools")
    (description "QubesDB VM-side daemon, command-line client, and Python bindings.")
    (license license:gpl2+)))

(define qubes-vm-qrexec
  (package
    (name "qubes-vm-qrexec")
    (version (qubes-release-version "qubes-core-qrexec"))
    (source (qubes-release-source "qubes-core-qrexec"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; Upstream tests exercise live qrexec/Xen service behavior; this package
      ;; build only installs the VM-side agent and helper programs.
      #:tests? #f
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (ice-9 textual-ports)
                  (srfi srfi-1)
                  (srfi srfi-13))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'support-guix-login-shell-paths
            (lambda _
              ;; The qrexec-agent environment buffer needs to hold Guix store
              ;; paths such as /gnu/store/...-bash-minimal/bin/bash.
              (substitute* "agent/qrexec-agent.c"
                (("    char env_buf\\[64\\];")
                 "    char env_buf[PATH_MAX];"))))
          (replace 'build
            (lambda _
              (invoke "make" "all-base" "PANDOC=true" "CC=gcc")
              ;; qrexec-agent switches QUBESRPC calls to the requested user and
              ;; exports HOME/USER/LOGNAME only in its PAM-enabled code path.
              ;; The upstream Makefile detects PAM through /usr/include, which
              ;; is not meaningful inside a Guix build container, so select PAM
              ;; with the upstream make variable when linux-pam is an input.
              (invoke "make" "all-vm" "PANDOC=true" "CC=gcc"
                      "HAVE_PAM_APPL=1"
                      (string-append "LDFLAGS=-pie -Wl,-z,relro,-z,now "
                                     "-L../libqrexec -Wl,-rpath="
                                     #$output "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "install-base" "install-vm"
                      (string-append "DESTDIR=" #$output)
                      "HAVE_PAM_APPL=1"
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "UNITDIR=/lib/systemd/system")
              ;; Upstream qubes.WaitForSession assumes systemd --user is
              ;; available after qrexec-fork-server appears.  Native Guix
              ;; templates use Shepherd, so keep the same qrexec-fork-server
              ;; readiness boundary and omit the systemd-only final check.
              (let* ((wait-for-session
                      (string-append #$output
                                     "/etc/qubes-rpc/qubes.WaitForSession"))
                     (wait-for-session-body
                      '(begin
                         (use-modules (ice-9 popen)
                                      (ice-9 textual-ports)
                                      (srfi srfi-13))

                         (define (trim-newlines text)
                           (let loop ((end (string-length text)))
                             (if (and (> end 0)
                                      (memv (string-ref text (- end 1))
                                            '(#\newline #\return)))
                                 (loop (- end 1))
                                 (substring text 0 end))))

                         (define (command-output program . args)
                           (let* ((port (apply open-pipe* OPEN_READ program args))
                                  (text (get-string-all port))
                                  (status (close-pipe port)))
                             (and (zero? status)
                                  (trim-newlines text))))

                         (define (qubesdb-read path)
                           (command-output
                            "/run/current-system/profile/bin/qubesdb-read"
                            path))

                         (define (non-empty text fallback)
                           (if (and text (not (string-null? text)))
                               text
                               fallback))

                         (define (warn message)
                           (display message (current-error-port))
                           (newline (current-error-port)))

                         (define (socket? path)
                           (let ((st (false-if-exception (stat path))))
                             (and st (eq? (stat:type st) 'socket))))

                         (unless (string=?
                                  (or (qubesdb-read "/qubes-gui-enabled")
                                      "True")
                                  "True")
                           (exit 0))
                         (let* ((user (non-empty (qubesdb-read "/default-user")
                                                 "user"))
                                (timeout-text
                                 (non-empty
                                  (getenv "QUBES_WAIT_FOR_SESSION_TIMEOUT")
                                  "300"))
                                (timeout (or (string->number timeout-text) 300))
                                (socket (string-append
                                         "/var/run/qubes/qrexec-server."
                                         user
                                         ".sock")))
                           (let loop ((elapsed 0))
                             (cond
                              ((socket? socket) (exit 0))
                              ((< elapsed timeout)
                               (sleep 1)
                               (loop (+ elapsed 1)))
                              (else
                               (warn (string-append
                                      "Timed out waiting for Guix Qubes session socket: "
                                      socket))
                               (exit 1))))))))
                ;; The upstream RPC entry is a symlink into /usr/bin.  Replace
                ;; the entry itself; otherwise call-with-output-file follows the
                ;; symlink and truncates the target helper instead.
                (false-if-exception (delete-file wait-for-session))
                (call-with-output-file wait-for-session
                  (lambda (port)
                    (display "#!/run/current-system/profile/bin/guile -s\n!#\n"
                             port)
                    (write wait-for-session-body port)
                    (newline port)))
                (chmod wait-for-session #o755)
                (let ((st (lstat wait-for-session))
                      (text (call-with-input-file wait-for-session
                              get-string-all)))
                  (unless (eq? (stat:type st) 'regular)
                    (error "qubes.WaitForSession must be a regular script"))
                  (unless (string-contains text
                                           "/var/run/qubes/qrexec-server.")
                    (error "qubes.WaitForSession script body was not emitted"))))
              (let ()
                (define (path-exists? path)
                  (false-if-exception (lstat path)))

              (define (non-symlink-directory? path)
                (let ((st (false-if-exception (lstat path))))
                  (and st (eq? (stat:type st) 'directory))))

              (define (delete-path path)
                (when (path-exists? path)
                  (if (non-symlink-directory? path)
                      (delete-file-recursively path)
                      (delete-file path))))

              (define (merge-tree source destination)
                (when (path-exists? source)
                  (mkdir-p destination)
                  (for-each
                   (lambda (name)
                     (let ((from (string-append source "/" name))
                           (to (string-append destination "/" name)))
                       (if (and (non-symlink-directory? from)
                                (non-symlink-directory? to))
                           (begin
                             (merge-tree from to)
                             (rmdir from))
                           (begin
                             (delete-path to)
                             (rename-file from to)))))
                   (scandir source
                            (lambda (entry)
                              (not (member entry '("." ".."))))))))

              (define (python-version-directory root)
                (let* ((lib (string-append root "/lib"))
                       (entries
                        (and (path-exists? lib)
                             (scandir lib
                                      (lambda (entry)
                                        (string-prefix? "python" entry))))))
                  (and entries (pair? entries) (car entries))))

              (define (python-site-packages root python-directory)
                (let ((site (string-append root "/lib/" python-directory
                                           "/site-packages")))
                  (and (path-exists? site) site)))

              (define (directory-entries directory)
                (or (false-if-exception
                     (scandir directory
                              (lambda (entry)
                                (not (member entry '("." ".."))))))
                    '()))

              (define (find-directory root name)
                (let loop ((directory root))
                  (and (path-exists? directory)
                       (or (and (string=? (basename directory) name)
                                directory)
                           (any (lambda (entry)
                                  (let ((child
                                         (string-append directory "/" entry)))
                                    (and (non-symlink-directory? child)
                                         (loop child))))
                                (directory-entries directory))))))

              (define (read-text path)
                (call-with-input-file path get-string-all))

              (define (write-text path text)
                (call-with-output-file path
                  (lambda (port)
                    (display text port))))

              (define (replace-once text needle replacement context)
                (let ((index (string-contains text needle)))
                  (unless index
                    (error "expected text not found" context))
                  (string-append (substring text 0 index)
                                 replacement
                                 (substring text
                                            (+ index (string-length needle))))))

              (define (python-quote text)
                (call-with-output-string
                  (lambda (port)
                    (display "'" port)
                    (string-for-each
                     (lambda (char)
                       (case char
                         ((#\\ #\')
                          (display "\\" port)
                          (display char port))
                         ((#\newline)
                          (display "\\n" port))
                         (else
                          (display char port))))
                     text)
                    (display "'" port))))

              (define (python-list entries)
                (string-append "[" (string-join (map python-quote entries) ", ")
                               "]"))

              (define python-directory
                (or (python-version-directory #$python-pyinotify)
                    (error "could not determine Python site-packages version")))
              (define site
                (string-append #$output "/lib/" python-directory
                               "/site-packages"))
              (define pythonpath
                (cons site
                      (filter-map
                       (lambda (root)
                         (python-site-packages root python-directory))
                       (list #$python-pyinotify))))

              (mkdir-p site)
              (let ((qrexec-source
                     (find-directory (string-append #$output "/gnu/store")
                                     "qrexec")))
                (unless qrexec-source
                  (error "qrexec Python package was not installed"))
                (delete-path (string-append site "/qrexec"))
                (copy-recursively qrexec-source
                                  (string-append site "/qrexec")))
              (for-each
               (lambda (pair)
                 (merge-tree (string-append #$output "/" (car pair))
                             (string-append #$output "/" (cdr pair))))
               '(("usr/bin" . "bin")
                 ("usr/lib/qubes" . "lib/qubes")
                 ("usr/lib/tmpfiles.d" . "lib/tmpfiles.d")
                 ("usr/include" . "include")
                 ("usr/share" . "share")))
              (let ((bindir (string-append #$output "/bin")))
                (when (path-exists? bindir)
                  (for-each
                   (lambda (name)
                     (let* ((script (string-append bindir "/" name))
                            (text (false-if-exception (read-text script))))
                       (when (and text
                                  (string-prefix? "#!/usr/bin/python3" text)
                                  (string-contains text "from qrexec."))
                         (write-text
                          script
                          (replace-once
                           text
                           "\nfrom qrexec."
                           (string-append "\nimport sys\nsys.path[:0] = "
                                          (python-list pythonpath)
                                          "\nfrom qrexec.")
                           script)))))
                   (scandir bindir
                            (lambda (entry)
                              (not (member entry '("." ".."))))))))
                (delete-path (string-append #$output "/gnu"))
                (delete-path (string-append #$output "/usr"))))))))
    (native-inputs (list pkg-config gzip python-setuptools))
    (inputs (list bash-minimal linux-pam python-pyinotify qubes-libvchan-xen
                  python-wrapper))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes qrexec VM agent")
    (description "VM-side qrexec agent and client tools for Qubes RPC.")
    (license license:gpl2+)))

(define qubes-vm-core
  (package
    (name "qubes-vm-core")
    (version (qubes-release-version "qubes-core-agent-linux"))
    (source (qubes-release-source "qubes-core-agent-linux"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The agent-linux tree is mostly VM filesystem, init, and hook
      ;; integration; its validation is integration-level in a Qubes TemplateVM.
      #:tests? #f
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (ice-9 textual-ports)
                  (srfi srfi-1)
                  (srfi srfi-13))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'normalize-guix-skel-in-home-init
            (lambda _
              ;; Guix exposes /etc/skel as a generated symlink to a store
              ;; directory and may include store-backed entries below it.
              ;; Qubes' home initializer uses cp -a -T, which would otherwise
              ;; preserve read-only store permissions in the persistent home.
              (substitute* "init/functions"
                (("cp \"-af\\$enable_selinux\" -T /etc/skel \"\\$home_root/\\$homedirwithouthome\"")
                 "skel_source=$(readlink -f /etc/skel || echo /etc/skel)\n            cp \"-afL$enable_selinux\" -T \"$skel_source\" \"$home_root/$homedirwithouthome\""))))
          (add-after 'normalize-guix-skel-in-home-init 'make-guix-skel-owner-writable
            (lambda _
              ;; Store directories are intentionally read-only.  Once copied
              ;; into /rw, the private home skeleton must behave like normal
              ;; per-user state so Guix and desktop tools can create entries
              ;; below ~/.config and ~/.cache.
              (substitute* "init/functions"
                (("            chmod 700 \"\\$home_root/\\$homedirwithouthome\" &"
                  all)
                 (string-append
                  "            chmod -R u+rwX \"$home_root/$homedirwithouthome\" || return 73\n"
                  all
                  )))))
          (add-after 'unpack 'support-networking-without-systemd
            (lambda _
              ;; Qubes' setup-ip applies network sysctls through
              ;; systemd-sysctl on systemd templates.  Native Guix templates
              ;; apply these settings with qubes-network-sysctl-service-type.
              (substitute* "network/setup-ip"
                (("/lib/systemd/systemd-sysctl") ":"))
              ;; The NetVM hotplug path re-applies the same hardening to newly
              ;; attached vif devices.  Keep that behavior by replacing only
              ;; the systemd executable with a Guile helper installed below.
              (substitute* "network/vif-route-qubes"
                (("/usr/lib/systemd/systemd-sysctl")
                 "/usr/lib/qubes/qubes-network-interface-sysctl"))))
          (replace 'build
            (lambda _
              (invoke "make" "-C" "qubes-rpc"
                      (string-append
                       "VERSION="
                       #$(qubes-release-version "qubes-core-agent-linux"))
                      "CC=gcc"
                      "release=Guix"
                      (string-append "LDFLAGS=-pie -Wl,-rpath="
                                     #$qubes-linux-utils-qrexec "/lib"))
              (invoke "make" "-C" "misc"
                      (string-append
                       "VERSION="
                       #$(qubes-release-version "qubes-core-agent-linux"))
                      "CC=gcc"
                      "release=Guix")))
          (replace 'install
            (lambda _
              (invoke "make" "install-corevm"
                      (string-append "DESTDIR=" #$output)
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "SYSTEM_DROPIN_DIR=/lib/systemd/system"
                      "USER_DROPIN_DIR=/lib/systemd/user"
                      "PYTHON=python3"
                      "DIST=guix"
                      "release=Guix")
              (invoke "make" "install-netvm"
                      (string-append "DESTDIR=" #$output)
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "SYSTEM_DROPIN_DIR=/lib/systemd/system"
                      "USER_DROPIN_DIR=/lib/systemd/user"
                      "PYTHON=python3"
                      "DIST=guix"
                      "release=Guix")
              (invoke "make" "-C" "qubes-rpc" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc")
              (invoke "make" "-C" "network" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc")
              ;; install-corevm intentionally skips packaging-specific payloads
              ;; that RPM/Debian specs install separately.  The post-install
              ;; qrexec hooks need these helpers to report supported features,
              ;; sync application menus, and expose /usr/share/qubes/marker-vm.
              (mkdir-p (string-append #$output "/usr/share/applications"))
              (invoke "make" "-C" "misc" "install"
                      (string-append "DESTDIR=" #$output))
              (invoke "make" "-C" "app-menu" "install"
                      (string-append "DESTDIR=" #$output))
              (invoke "make" "-C" "filesystem" "install"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc"
                      "STATEDIR=/var/lib")
              (let ()
                (define (path-exists? path)
                  (false-if-exception (lstat path)))

              (define (non-symlink-directory? path)
                (let ((st (false-if-exception (lstat path))))
                  (and st (eq? (stat:type st) 'directory))))

              (define (delete-path path)
                (when (path-exists? path)
                  (if (non-symlink-directory? path)
                      (delete-file-recursively path)
                      (delete-file path))))

              (define (merge-tree source destination)
                (when (path-exists? source)
                  (mkdir-p destination)
                  (for-each
                   (lambda (name)
                     (let ((from (string-append source "/" name))
                           (to (string-append destination "/" name)))
                       (if (and (non-symlink-directory? from)
                                (non-symlink-directory? to))
                           (begin
                             (merge-tree from to)
                             (rmdir from))
                           (begin
                             (delete-path to)
                             (rename-file from to)))))
                   (scandir source
                            (lambda (entry)
                              (not (member entry '("." ".."))))))))

              (define (python-version-directory root)
                (let* ((lib (string-append root "/lib"))
                       (entries
                        (and (path-exists? lib)
                             (scandir lib
                                      (lambda (entry)
                                        (string-prefix? "python" entry))))))
                  (and entries (pair? entries) (car entries))))

              (define (python-site-packages root python-directory)
                (let ((site (string-append root "/lib/" python-directory
                                           "/site-packages")))
                  (and (path-exists? site) site)))

              (define (read-text path)
                (call-with-input-file path get-string-all))

              (define (write-text path text)
                (mkdir-p (dirname path))
                (call-with-output-file path
                  (lambda (port)
                    (display text port))))

              (define (replace-once text needle replacement context)
                (let ((index (string-contains text needle)))
                  (unless index
                    (error "expected text not found" context))
                  (string-append (substring text 0 index)
                                 replacement
                                 (substring text
                                            (+ index (string-length needle))))))

              (define (patch-file-once path needle replacement)
                (write-text path
                            (replace-once (read-text path)
                                          needle
                                          replacement
                                          path)))

              (define (python-quote text)
                (call-with-output-string
                  (lambda (port)
                    (display "'" port)
                    (string-for-each
                     (lambda (char)
                       (case char
                         ((#\\ #\')
                          (display "\\" port)
                          (display char port))
                         ((#\newline)
                          (display "\\n" port))
                         (else
                          (display char port))))
                     text)
                    (display "'" port))))

              (define (python-list entries)
                (string-append "[" (string-join (map python-quote entries) ", ")
                               "]"))

              (define (write-guile-script path expression)
                (mkdir-p (dirname path))
                (call-with-output-file path
                  (lambda (port)
                    (display "#!/run/current-system/profile/bin/guile -s\n" port)
                    (display "!#\n" port)
                    (write expression port)
                    (newline port)))
                (chmod path #o755))

              (define (write-python-wrapper path pythonpath module)
                (write-text
                 path
                 (string-append
                  "#!" (which "python3") "\n"
                  "import sys\n"
                  "sys.path[:0] = " (python-list pythonpath) "\n"
                  "from " module " import main\n"
                  "if __name__ == '__main__':\n"
                  "    raise SystemExit(main())\n"))
                (chmod path #o755))

              (define python-directory
                (or (python-version-directory #$python-pygobject)
                    (error "could not determine Python site-packages version")))
              (define site
                (string-append #$output "/lib/" python-directory
                               "/site-packages"))
              (define extra-pythonpath
                (filter-map
                 (lambda (root)
                   (python-site-packages root python-directory))
                 (list #$qubesdb-vm #$python-dbus
                       #$python-pygobject #$python-pyxdg)))
              (define pythonpath
                (cons site extra-pythonpath))
              (define bindir
                (string-append #$output "/bin"))
              (define qubes-libdir
                (string-append #$output "/lib/qubes"))

              (for-each
               (lambda (pair)
                 (merge-tree (string-append #$output "/" (car pair))
                             (string-append #$output "/" (cdr pair))))
               '(("usr/bin" . "bin")
                 ("usr/lib" . "lib")
                 ("usr/share" . "share")))
              (delete-path (string-append #$output "/usr"))
              (mkdir-p site)
              (delete-path (string-append site "/qubesagent"))
              (copy-recursively "build/lib/qubesagent"
                                (string-append site "/qubesagent"))
              (mkdir-p bindir)

              (let ((postinstall
                     (string-append #$output
                                    "/etc/qubes-rpc/qubes.PostInstall")))
                (when (path-exists? postinstall)
                  ;; Qubes RPC services do not necessarily run through a login
                  ;; shell.  Give post-install hooks the profile-visible commands
                  ;; used by the Guix VM.
                  (patch-file-once
                   postinstall
                   "\nfor script in /etc/qubes/post-install.d/*.sh; do\n"
                   "\nexport PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin${PATH:+:$PATH}\n\nfor script in /etc/qubes/post-install.d/*.sh; do\n")))

              (let ((filecopy
                     (string-append #$output
                                    "/etc/qubes-rpc/qubes.Filecopy")))
                (when (path-exists? filecopy)
                  ;; Guix exposes setuid/setgid programs from a runtime
                  ;; privileged directory instead of trusting mode bits inside
                  ;; the store.  Keep upstream's absolute RPC service path
                  ;; working by resolving qfile-unpacker through that runtime
                  ;; copy first.
                  (patch-file-once
                   filecopy
                   "exec /usr/lib/qubes/qfile-unpacker $arg\n"
                   "for unpacker in /run/setuid-programs/qfile-unpacker /run/privileged/bin/qfile-unpacker /usr/lib/qubes/qfile-unpacker; do\n    if [ -x \"$unpacker\" ]; then\n        exec \"$unpacker\" $arg\n    fi\ndone\necho \"qfile-unpacker not found\" >&2\nexit 127\n")))

              (write-text
               (string-append #$output "/etc/qubes/rpc-config/qubes.PostInstall")
               "force-user = 'root'\n")

              (mkdir-p qubes-libdir)
              (write-guile-script
               (string-append qubes-libdir "/guix-updates-proxy-forwarder")
               '(begin
                  (execl "/run/current-system/profile/bin/qrexec-client-vm"
                         "qrexec-client-vm"
                         "--use-stdin-socket"
                         ""
                         "qubes.UpdatesProxy")))
              (let ((repo-query
                     (string-append qubes-libdir
                                    "/qvm-template-repo-query"))
                    (dnf-repo-query
                     (string-append qubes-libdir
                                    "/qvm-template-repo-query.dnf"))
                    (guix-repo-query
                     (string-append qubes-libdir
                                    "/qvm-template-repo-query-guix")))
                (copy-file #$%qvm-template-repo-query-guix guix-repo-query)
                (substitute* guix-repo-query
                  (("#!/run/current-system/profile/bin/python3")
                   (string-append "#!" #$python "/bin/python3"))
                  (("\\[\"curl\"")
                   (string-append "[\"" #$curl "/bin/curl\""))
                  (("\\[\"zstd\"")
                   (string-append "[\"" #$zstd "/bin/zstd\"")))
                (chmod guix-repo-query #o755)
                (when (path-exists? repo-query)
                  (rename-file repo-query dnf-repo-query)
                  (write-text
                   repo-query
                   (string-append
                    "#!" #$bash-minimal "/bin/bash\n"
                    "set -e\n"
                    "script_dir=\"$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd -P)\"\n"
                    "if command -v dnf5 >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v dnf4 >/dev/null 2>&1; then\n"
                    "    exec \"$script_dir/qvm-template-repo-query.dnf\" \"$@\"\n"
                    "fi\n"
                    "exec \"$script_dir/qvm-template-repo-query-guix\" \"$@\"\n"))
                  (chmod repo-query #o755)))
              (write-guile-script
               (string-append qubes-libdir
                              "/qubes-network-interface-sysctl")
               '(begin
                  (use-modules (ice-9 match)
                               (srfi srfi-1)
                               (srfi srfi-13))

                  (define settings
                    '(("ipv4" "accept_source_route" . "0")
                      ("ipv4" "accept_redirects" . "0")
                      ("ipv4" "secure_redirects" . "0")
                      ("ipv4" "send_redirects" . "0")
                      ("ipv4" "drop_unicast_in_l2_multicast" . "1")
                      ("ipv6" "accept_source_route" . "-1")
                      ("ipv6" "accept_redirects" . "0")
                      ("ipv6" "accept_ra" . "0")
                      ("ipv6" "accept_dad" . "0")
                      ("ipv6" "autoconf" . "0")
                      ("ipv6" "drop_unicast_in_l2_multicast" . "1")))

                  (define (warn message)
                    (display message (current-error-port))
                    (newline (current-error-port)))

                  (define (arg-prefix arg)
                    (and (string-prefix? "--prefix=" arg)
                         (substring arg (string-length "--prefix="))))

                  (define (prefix->target prefix)
                    (match (string-split prefix #\/)
                      (("" "net" family "conf" interface)
                       (cons family interface))
                      (_ #f)))

                  (define targets
                    (delete-duplicates
                     (filter-map prefix->target
                                 (filter-map arg-prefix
                                             (cdr (command-line))))
                     equal?))

                  (define (write-sysctl family interface name value)
                    (let ((path (string-append "/proc/sys/net/" family
                                               "/conf/" interface "/"
                                               name)))
                      (when (file-exists? path)
                        (catch #t
                          (lambda ()
                            (call-with-output-file path
                              (lambda (port)
                                (display value port)
                                (newline port))))
                          (lambda (key . args)
                            (warn (string-append
                                   "failed to write network sysctl: "
                                   path))
                            (exit 1))))))

                  (for-each
                   (match-lambda
                     ((family . interface)
                      (for-each
                       (lambda (setting)
                         (when (string=? (car setting) family)
                           (write-sysctl family interface
                                         (cadr setting)
                                         (cddr setting))))
                       settings)))
                   targets)))
              (for-each
               (lambda (helper)
                 (let ((destination (string-append qubes-libdir "/" helper)))
                   (copy-file (string-append "package-managers/" helper)
                              destination)
                   (chmod destination #o755)))
               '("upgrades-installed-check" "upgrades-status-notify"))

              (let ((installed-check
                     (string-append qubes-libdir "/upgrades-installed-check")))
                (unless (string-contains (read-text installed-check)
                                         "## Guix System")
                  (patch-file-once
                   installed-check
                   "elif [ -e /etc/arch-release ]; then\n"
                   (string-append
                    "elif [ -e /run/current-system ]; then\n"
                    "    ## Guix System\n"
                    "    # There is no cheap metadata-only Guix System update check comparable to\n"
                    "    # dnf check-update or apt-get -s upgrade.  The Qubes vmupdate backend\n"
                    "    # reports system/profile changes while reconfiguring; this helper only\n"
                    "    # clears the post-update notification state after that succeeds.\n"
                    "    echo true\n"
                    "    exit_code=0\n"
                    "elif [ -e /etc/arch-release ]; then\n"))))

              (let ((features-request
                     (string-append bindir "/qvm-features-request")))
                (when (path-exists? features-request)
                  (patch-file-once
                   features-request
                   "import argparse\n"
                   (string-append "import sys\nsys.path[:0] = "
                                  (python-list pythonpath)
                                  "\n\nimport argparse\n"))
                  ;; Native Guix templates use Shepherd, not systemd.  The
                  ;; post-install RPC itself proves qrexec-agent is active, so
                  ;; preserve feature reporting when systemctl is absent.
                  (patch-file-once
                   features-request
                   "def is_active(service):\n    status = subprocess.call([\"systemctl\", \"is-active\", \"--quiet\", service])\n    return status == 0\n"
                   "def is_active(service):\n    try:\n        status = subprocess.call([\"systemctl\", \"is-active\", \"--quiet\", service])\n    except FileNotFoundError:\n        return service == \"qubes-qrexec-agent\"\n    return status == 0\n")))

              (let ((session-autostart
                     (string-append bindir "/qubes-session-autostart")))
                (when (path-exists? session-autostart)
                  (patch-file-once
                   session-autostart
                   "import sys\n"
                   (string-append "import sys\nsys.path[:0] = "
                                  (python-list pythonpath)
                                  "\n"))))
              (let ((start-app
                     (string-append #$output "/etc/qubes-rpc/qubes.StartApp")))
                (when (path-exists? start-app)
                  (patch-file-once
                   start-app
                   "import sys, os, pwd\n"
                   (string-append "import sys, os, pwd\nsys.path[:0] = "
                                  (python-list pythonpath)
                                  "\n"))))
              (let ((desktop-run
                     (string-append bindir "/qubes-desktop-run")))
                (when (path-exists? desktop-run)
                  (patch-file-once
                   desktop-run
                   "from qubesagent.xdg import launch\nimport sys\n"
                   (string-append "import sys\nsys.path[:0] = "
                                  (python-list pythonpath)
                                  "\nfrom qubesagent.xdg import launch\n"))))
              (let ((xdg-launcher
                     (string-append site "/qubesagent/xdg.py")))
                (when (path-exists? xdg-launcher)
                  (patch-file-once
                   xdg-launcher
                   "import functools\n\n"
                   (string-append
                    "import functools\n"
                    "import os\n\n"
                    "_gi_typelib_path = '" #$glib
                    "/lib/girepository-1.0'\n"
                    "os.environ['GI_TYPELIB_PATH'] = _gi_typelib_path + "
                    "(':' + os.environ['GI_TYPELIB_PATH'] "
                    "if os.environ.get('GI_TYPELIB_PATH') else '')\n\n"))))

              (for-each
               (lambda (entry)
                 (write-python-wrapper
                  (string-append bindir "/" (car entry))
                  pythonpath
                  (cdr entry)))
               '(("qubes-firewall" . "qubesagent.firewall")
                 ("qubes-vmexec" . "qubesagent.vmexec")))
              (delete-path (string-append #$output "/gnu"))
              (for-each
               (lambda (stale)
                 (delete-path (string-append #$output "/usr/bin/" stale)))
               '("qubes-firewall" "qubes-vmexec"))))))))
    (native-inputs (list desktop-file-utils pandoc pkg-config python-wrapper
                         python-setuptools shared-mime-info))
    (inputs (list bash-minimal conntrack-tools coreutils gawk grep iproute
                  glib nftables procps sed python-dbus python-pygobject
                  python-pyxdg
                  qubes-linux-utils-qrexec
                  qubesdb-vm qubes-vm-qrexec socat))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes Linux VM core scripts")
    (description "Core VM-side Qubes scripts, RPC services, and compatibility files.")
    (license license:gpl2+)))

(define qubes-vm-gui-common
  (package
    (name "qubes-vm-gui-common")
    (version (qubes-release-version "qubes-gui-common"))
    (source (qubes-release-source "qubes-gui-common"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("include" "include"))))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes GUI protocol headers")
    (description "Common Qubes GUI protocol headers.")
    (license license:gpl2+)))

(define qubes-vm-gui
  (package
    (name "qubes-vm-gui")
    (version (qubes-release-version "qubes-gui-agent-linux"))
    (source (qubes-release-source "qubes-gui-agent-linux"))
    (build-system gnu-build-system)
    (arguments
     (list
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (srfi srfi-13))
      ;; GUI agent tests require a running Qubes GUI/Xen display environment;
      ;; this package build installs the VM-side GUI agent and Xorg helpers.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'patch-generated-configure-invocation
            (lambda _
              ;; The Xorg driver helper scripts generate configure scripts
              ;; after Guix's shebang patching phase. Invoke those generated
              ;; scripts through the profile shell instead of relying on
              ;; /bin/sh inside the build container.
              (substitute* '("xf86-input-mfndev/autogen.sh"
                             "xf86-video-dummy/autogen.sh")
                (("\\$srcdir/configure")
                 "${CONFIG_SHELL:-sh} $srcdir/configure"))
              (substitute* "Makefile"
                (("&& \\./configure")
                 "&& ${CONFIG_SHELL:-sh} ./configure"))))
          (replace 'build
            (lambda _
              ;; Build the GUI/Xorg pieces needed for Qubes application
              ;; forwarding without pulling in the audio-specific
              ;; PulseAudio/PipeWire module targets.
              (let ((shell (which "sh")))
                (setenv "CONFIG_SHELL" shell)
                (setenv "SHELL" shell))
              (setenv "CPPFLAGS" (string-append "-I" #$xen "/include"))
              (setenv "LDFLAGS" (string-append "-L" #$xen-vchan-libs "/lib "
                                                "-Wl,-rpath="
                                                #$xen-vchan-libs "/lib"))
              (invoke "make"
                      "gui-agent/qubes-gui"
                      "gui-agent/qubes-gui-runuser"
                      "xf86-qubes-common/libxf86-qubes-common.so"
                      "CC=gcc")
              ;; The top-level Qubes Makefile invokes generated configure
              ;; scripts directly. Build these helpers explicitly so Guix can
              ;; run those generated scripts through CONFIG_SHELL.
              (for-each
               (lambda (directory)
                 (with-directory-excursion directory
                   (invoke (getenv "CONFIG_SHELL") "./autogen.sh"))
                 (invoke "make" "-C" directory "CC=gcc"))
               '("xf86-input-mfndev" "xf86-video-dummy"))))
          (replace 'install
            (lambda _
              (define (move-profile-tree source destination)
                (when (file-exists? source)
                  (mkdir-p destination)
                  (for-each
                   (lambda (entry)
                     (let ((from (string-append source "/" entry))
                           (to (string-append destination "/" entry)))
                       (when (file-exists? to)
                         (delete-file-recursively to))
                       (rename-file from to)))
                   (scandir source
                            (lambda (entry)
                              (not (member entry '("." ".."))))))))

              (invoke "make" "install-common" "install-systemd"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "USRLIBDIR=/lib"
                      "SYSLIBDIR=/lib")
              ;; qrexec-fork-server daemonizes itself.  Keep upstream's XDG
              ;; autostart launcher as the single owner of that user-session
              ;; daemon instead of supervising it from Shepherd.
              (unless (file-exists?
                       (string-append #$output
                                      "/etc/xdg/autostart/qubes-qrexec-fork-server.desktop"))
                (error "missing qrexec-fork-server.desktop"))
              (install-file "appvm-scripts/etc/sysconfig/desktop"
                            (string-append #$output "/etc/sysconfig"))
              (for-each
               (lambda (script)
                 (install-file
                  script
                  (string-append #$output "/etc/X11/xinit/xinitrc.d")))
               '("appvm-scripts/etc/X11/xinit/xinitrc.d/20qt-x11-no-mitshm.sh"
                 "appvm-scripts/etc/X11/xinit/xinitrc.d/20qt-gnome-desktop-session-id.sh"
                 "appvm-scripts/etc/X11/xinit/xinitrc.d/50guivm-windows-prefix.sh"
                 "appvm-scripts/etc/X11/xinit/xinitrc.d/60xfce-desktop.sh"))
              ;; The upstream non-GuiVM path starts xinit through
              ;; qubes-gui-runuser so Xorg itself runs as the default user.
              ;; In this Guix System image there is no distro Xorg wrapper or
              ;; logind setup granting an unprivileged user access to vt07, so
              ;; Xorg exits before the Qubes GUI socket appears.  Keep the
              ;; session side unprivileged, but let root own xinit/Xorg.
              ;; Guix xinit's default xinitrc sources its immutable store
              ;; xinitrc.d, not the profile hook above, so run qubes-session
              ;; directly.  The upstream XDG autostart launcher remains the
              ;; owner of qrexec-fork-server; qubes.WaitForSession waits for
              ;; that server's socket.  The -ac flag is a review-sensitive
              ;; compatibility choice for this root-owned Xorg/user-session
              ;; split: the first-review image does not yet provide a distro
              ;; logind/xauth handoff that would otherwise authorize the
              ;; default user's Qubes session client.
              (substitute* (string-append #$output "/usr/bin/qubes-run-xorg")
                (("qubes-xorg-wrapper \\$DISPLAY_XORG -nolisten")
                 "qubes-xorg-wrapper $DISPLAY_XORG -modulepath /run/current-system/profile/lib/xorg/modules -fp /run/current-system/profile/share/fonts/X11/misc -nolisten")
                (("exec /usr/bin/qubes-gui-runuser \"\\$DEFAULT_USER\" /bin/sh -l -c \"exec /usr/bin/xinit \\$XSESSION -- /usr/lib/qubes/qubes-xorg-wrapper :0 -nolisten tcp vt07 -wr -config xorg-qubes.conf > ~/.xsession-errors 2>&1\"")
                 "exec /usr/bin/xinit /usr/bin/qubes-gui-runuser \"$DEFAULT_USER\" /usr/bin/env DISPLAY=:0 XDG_CONFIG_DIRS=/run/current-system/profile/etc/xdg XDG_DATA_DIRS=/run/current-system/profile/share GI_TYPELIB_PATH=/run/current-system/profile/lib/girepository-1.0 PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin /usr/bin/qubes-session qubes-session -- /usr/lib/qubes/qubes-xorg-wrapper :0 -modulepath /run/current-system/profile/lib/xorg/modules -fp /run/current-system/profile/share/fonts/X11/misc -nolisten tcp vt07 -wr -config xorg-qubes.conf -ac > \"/home/$DEFAULT_USER/.xsession-errors\" 2>&1"))
              ;; install-common follows the distribution FHS and places the
              ;; agent under /usr.  Guix profiles do not merge /usr/bin into
              ;; /bin, and the compatibility activation links /usr/lib/qubes
              ;; to profile/lib/qubes, so normalize those trees into the
              ;; profile-visible locations.
              (move-profile-tree (string-append #$output "/usr/bin")
                                 (string-append #$output "/bin"))
              (move-profile-tree (string-append #$output "/usr/lib")
                                 (string-append #$output "/lib"))
              (move-profile-tree (string-append #$output "/usr/share")
                                 (string-append #$output "/share"))
              (move-profile-tree (string-append #$output "/usr/include")
                                 (string-append #$output "/include"))
              (let ((qubes-session
                     (string-append #$output "/bin/qubes-session")))
                (when (file-exists? qubes-session)
                  (substitute*
                      qubes-session
                    (("export QUBES_ENV_SOURCED=1\n")
                     (string-append
                      "export QUBES_ENV_SOURCED=1\n"
                      "\n"
                      "# The native Guix session is started directly from xinit,\n"
                      "# so make the GUI/profile environment explicit before\n"
                      "# XDG autostart launches qrexec-fork-server.  Qubes\n"
                      "# StartApp services inherit that daemon environment.\n"
                      ": \"${DISPLAY:=:0}\"\n"
                      ": \"${XDG_RUNTIME_DIR:=/tmp/qubes-runtime-$(id -u)}\"\n"
                      ": \"${XDG_CONFIG_DIRS:=/run/current-system/profile/etc/xdg}\"\n"
                      ": \"${XDG_DATA_DIRS:=/run/current-system/profile/share}\"\n"
                      ": \"${GI_TYPELIB_PATH:=/run/current-system/profile/lib/girepository-1.0}\"\n"
                      ": \"${SSL_CERT_DIR:=/etc/ssl/certs}\"\n"
                      ": \"${SSL_CERT_FILE:=/etc/ssl/certs/ca-certificates.crt}\"\n"
                      ": \"${GIT_SSL_CAINFO:=/etc/ssl/certs/ca-certificates.crt}\"\n"
                      ": \"${CURL_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}\"\n"
                      ": \"${XDG_CACHE_HOME:=/var/tmp/guix-cache-${USER:-user}}\"\n"
                      "mkdir -p \"$XDG_RUNTIME_DIR\"\n"
                      "chmod 700 \"$XDG_RUNTIME_DIR\"\n"
                      ": \"${DBUS_SESSION_BUS_ADDRESS:=unix:path=$XDG_RUNTIME_DIR/bus}\"\n"
                      "if [ ! -S \"$XDG_RUNTIME_DIR/bus\" ]; then\n"
                      "    dbus-daemon --session --address=\"$DBUS_SESSION_BUS_ADDRESS\" --fork --nopidfile\n"
                      "fi\n"
                      "PATH=\"/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}\"\n"
                      "export DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS\n"
                      "export XDG_CONFIG_DIRS XDG_DATA_DIRS GI_TYPELIB_PATH\n"
                      "export SSL_CERT_DIR SSL_CERT_FILE GIT_SSL_CAINFO CURL_CA_BUNDLE XDG_CACHE_HOME PATH\n")))
                  (substitute* qubes-session
                    (("dbus-update-activation-environment --systemd --all")
                     "dbus-update-activation-environment --all || true"))))
              (let* ((python-site-packages
                      (lambda (package)
                        (let* ((python-lib (string-append package "/lib"))
                               (python-directory
                                (car (scandir
                                      python-lib
                                      (lambda (entry)
                                        (string-prefix? "python" entry))))))
                          (string-append python-lib "/" python-directory
                                         "/site-packages"))))
                     (pythonpath
                      (map python-site-packages
                           (list #$python-xcffib #$python-cffi
                                 #$python-pycparser)))
                     (icon-sender
                      (string-append #$output "/lib/qubes/icon-sender")))
                (when (file-exists? icon-sender)
                  (substitute* icon-sender
                    (("import xcffib")
                     (string-append "import sys\n"
                                    "sys.path[:0] = ['"
                                    (string-join pythonpath "', '")
                                    "']\n"
                                    "import xcffib")))))
              ;; Upstream installs these Qubes RPC entries as FHS-relative
              ;; symlinks into /usr/bin.  After normalizing /usr/bin into the
              ;; Guix profile's /bin, keep the qrexec services executable.
              (for-each
               (lambda (entry)
                 (let ((link (string-append #$output "/etc/qubes-rpc/"
                                            (car entry))))
                   (false-if-exception (delete-file link))
                   (symlink (string-append "../../bin/" (cdr entry)) link)))
               '(("qubes.SetMonitorLayout" . "qubes-set-monitor-layout")
                 ("qubes.GuiVMSession" . "qubes-start-xephyr")))
              (when (file-exists? (string-append #$output "/usr"))
                (delete-file-recursively (string-append #$output "/usr")))))
          (add-after 'install 'set-xorg-driver-runpath
            (lambda _
              (for-each
               (lambda (driver)
                 (invoke "patchelf" "--add-rpath"
                         (string-append #$output "/lib")
                         (string-append #$output "/lib/xorg/modules/drivers/"
                                        driver)))
               '("qubes_drv.so" "dummyqbs_drv.so")))))))
    (native-inputs (list autoconf automake libtool patchelf pkg-config xen))
    (inputs (list dbus libunistring libx11 libxcomposite libxcursor
                  libxdamage libxext libxfixes libxt linux-pam pixman
                  qubes-libvchan-xen qubes-vm-gui-common qubesdb-vm
                  xen-vchan-libs xorg-server))
    (propagated-inputs (list python-cffi python-pycparser python-xcffib))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes GUI agent")
    (description "VM-side Qubes GUI agent for X11 application forwarding.")
    (license license:gpl2+)))

(define %qubes-vm-headless-packages
  (list qubes-libvchan-xen qubes-vm-utils qubesdb-vm qubes-vm-qrexec
        qubes-vm-core xen-network-hotplug-tools))

(define %qubes-vm-gui-packages
  (append %qubes-vm-headless-packages
          (list qubes-vm-gui-common qubes-vm-gui)))

;;; Qubes VM service definitions
;; SPDX-License-Identifier: GPL-3.0-or-later

(define (qubes-vm-compat-activation _)
  #~(begin
      (use-modules (guix build utils)
                   (ice-9 ftw))

      (define (empty-directory? directory)
        (null? (scandir directory
                        (lambda (entry)
                          (not (member entry '("." "..")))))))

      (define (replace-symlink target link)
        (mkdir-p (dirname link))
        (let ((existing (false-if-exception (lstat link))))
          (cond
           ((and existing (memq (stat:type existing) '(regular symlink)))
            (delete-file link))
           ((and existing
                 (eq? (stat:type existing) 'directory)
                 (empty-directory? link))
            (rmdir link)))
          (unless (file-exists? link)
            (symlink target link))))

      (define (symlink?* path)
        (let ((existing (false-if-exception (lstat path))))
          (and existing (eq? (stat:type existing) 'symlink))))

      (define (regular-or-symlink? path)
        (let ((existing (false-if-exception (lstat path))))
          (and existing (memq (stat:type existing) '(regular symlink)))))

      (define (same-directory-entry? left right)
        (let ((left-stat (false-if-exception (stat left)))
              (right-stat (false-if-exception (stat right))))
          (and left-stat right-stat
               (= (stat:dev left-stat) (stat:dev right-stat))
               (= (stat:ino left-stat) (stat:ino right-stat)))))

      (define (link-directory-contents source directory)
        (materialize-symlinked-directory directory)
        (mkdir-p directory)
        (unless (symlink?* directory)
          (when (file-exists? source)
            (for-each
             (lambda (entry)
               (let ((target (string-append source "/" entry))
                     (link (string-append directory "/" entry)))
                 (when (symlink?* link)
                   (delete-file link))
                 (unless (file-exists? link)
                   (symlink target link))))
             (scandir source
                      (lambda (entry)
                        (not (member entry '("." "..")))))))))

      (define (write-text-file path text)
        (mkdir-p (dirname path))
        (call-with-output-file path
          (lambda (port)
            (display text port))))

      (define tls-profile-script
        (string-append
         "export SSL_CERT_DIR=${SSL_CERT_DIR:-/etc/ssl/certs}\n"
         "export SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}\n"
         "export GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-/etc/ssl/certs/ca-certificates.crt}\n"
         "export CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}\n"))

      (define guix-cache-profile-script
        (string-append
         "if [ \"${XDG_CACHE_HOME+x}\" != x ]; then\n"
         "    export XDG_CACHE_HOME=/var/tmp/guix-cache-${USER:-user}\n"
         "fi\n"))

      (define (materialize-symlinked-directory directory)
        (let ((existing (false-if-exception (lstat directory))))
          (when (and existing (eq? (stat:type existing) 'symlink))
            (let* ((target (readlink directory))
                   (absolute-target
                    (if (and (positive? (string-length target))
                             (char=? (string-ref target 0) #\/))
                        target
                        (string-append (dirname directory) "/" target)))
                   (temporary (string-append directory ".qubes-tmp")))
              (when (file-exists? temporary)
                (delete-file-recursively temporary))
              (mkdir-p temporary)
              (when (file-exists? absolute-target)
                (copy-recursively absolute-target temporary))
              (delete-file directory)
              (rename-file temporary directory)))))

      (define (materialize-symlinked-file file)
        (let ((existing (false-if-exception (lstat file))))
          (when (and existing (eq? (stat:type existing) 'symlink))
            (let* ((target (readlink file))
                   (absolute-target
                    (if (and (positive? (string-length target))
                             (char=? (string-ref target 0) #\/))
                        target
                        (string-append (dirname file) "/" target)))
                   (temporary (string-append file ".qubes-tmp")))
              (when (file-exists? temporary)
                (delete-file temporary))
              (when (file-exists? absolute-target)
                (copy-file absolute-target temporary)
                (chmod temporary #o644)
                (delete-file file)
                (rename-file temporary file))))))

      ;; The upstream Qubes VM tools use fixed paths. Keep those paths as
      ;; compatibility links into the current Guix system profile.
      (mkdir-p "/usr/lib")
      (mkdir-p "/etc")
      (mkdir-p "/run/qubes")
      (mkdir-p "/run/qubes-service")
      (mkdir-p "/var/log/qubes")
      (mkdir-p "/var/lib/qubes")
      (mkdir-p "/var/tmp")
      (mkdir-p "/rw")
      (mkdir-p "/usr/local")
      (chmod "/var/tmp" #o1777)
      ;; Guix exposes /etc/fstab as an immutable store symlink.  Qubes'
      ;; mount-dirs script expects to add the private /rw volume there.
      (materialize-symlinked-file "/etc/fstab")
      (write-text-file "/etc/acpi/events/qubes-power-button"
                       "event=button/power.*\naction=/etc/acpi/actions/qubes-poweroff\n")
      (write-text-file "/etc/acpi/actions/qubes-poweroff"
                       "#!/run/current-system/profile/bin/guile -s
!#
(execl \"/run/current-system/profile/sbin/halt\" \"halt\")
")
      (chmod "/etc/acpi/actions/qubes-poweroff" #o555)
      (replace-symlink "/run/current-system/profile/bin" "/usr/bin")
      (replace-symlink "/run/current-system/profile/sbin" "/usr/sbin")
      (replace-symlink "/run/current-system/profile/share" "/usr/share")
      (replace-symlink "/run/current-system/profile/lib/qubes" "/usr/lib/qubes")
      (replace-symlink "/run/current-system/profile/lib/qubes-bind-dirs.d"
                       "/usr/lib/qubes-bind-dirs.d")
      (link-directory-contents "/run/current-system/profile/etc/qubes"
                               "/etc/qubes")
      (materialize-symlinked-directory "/etc/qubes/post-install.d")
      (mkdir-p "/etc/qubes/post-install.d")
      (link-directory-contents "/run/current-system/profile/etc/xen"
                               "/etc/xen")
      ;; Official Qubes system tests and local administrators create ad-hoc
      ;; services in /etc/qubes-rpc and post-install hooks below /etc/qubes.
      ;; Keep packaged entries visible, but make the top-level directories
      ;; writable instead of immutable profile symlinks.
      (link-directory-contents "/run/current-system/profile/etc/qubes-rpc"
                               "/etc/qubes-rpc")
      ;; Qubes' init/functions still use /var/run/qubes-service* while
      ;; qubes-sysinit.sh populates /run/qubes-service*.  Bridge those paths
      ;; only on systems where /var/run is not already /run.
      (unless (same-directory-entry? "/var/run" "/run")
        (replace-symlink "/run/qubes" "/var/run/qubes")
        (replace-symlink "/run/qubes-service" "/var/run/qubes-service")
        (replace-symlink "/run/qubes-service-environment"
                         "/var/run/qubes-service-environment"))
      (link-directory-contents "/run/current-system/profile/etc/X11" "/etc/X11")
      (link-directory-contents "/run/current-system/profile/etc/sysconfig"
                               "/etc/sysconfig")
      (link-directory-contents "/run/current-system/profile/etc/profile.d"
                               "/etc/profile.d")
      (for-each
       (lambda (path)
         (when (regular-or-symlink? path)
           (delete-file path)))
       '("/etc/profile.d/qubes-guix-session.sh"
         "/etc/profile.d/qubes-guix-update-proxy.sh"
         "/run/qubes/bin/guix"))
      (write-text-file "/etc/profile.d/qubes-guix-tls.sh" tls-profile-script)
      (chmod "/etc/profile.d/qubes-guix-tls.sh" #o644)
      (write-text-file "/etc/profile.d/qubes-guix-cache.sh"
                       guix-cache-profile-script)
      (chmod "/etc/profile.d/qubes-guix-cache.sh" #o644)
      (link-directory-contents "/run/current-system/profile/bin" "/bin")
      (link-directory-contents "/run/current-system/profile/bin" "/usr/bin")
      (link-directory-contents "/run/current-system/profile/sbin" "/sbin")
      (replace-symlink "/run/current-system/profile/sbin/halt" "/sbin/poweroff")))

(define qubes-vm-compat-service-type
  (service-type
   (name 'qubes-vm-compat)
   (extensions
    (list (service-extension activation-service-type qubes-vm-compat-activation)))
   (default-value #f)
   (description "Create compatibility paths expected by Qubes VM agents.")))

(define (qubes-pam-service name)
  (let ((pam-module (lambda (name)
                      (file-append linux-pam "/lib/security/" name))))
    (pam-service
     (name name)
     (auth (list (pam-entry
                  (control "sufficient")
                  (module (pam-module "pam_rootok.so")))
                 (pam-entry
                  (control "required")
                  (module (pam-module "pam_permit.so")))))
     (account (list (pam-entry
                     (control "required")
                     (module (pam-module "pam_permit.so")))))
     (password (list (pam-entry
                      (control "required")
                      (module (pam-module "pam_permit.so")))))
     (session (list (pam-entry
                     (control "required")
                     (module (pam-module "pam_permit.so"))))))))

(define (qubes-qrexec-pam-services _)
  (list (qubes-pam-service "qrexec")
        (qubes-pam-service "qubes-gui-agent")))

(define qubes-qrexec-pam-service-type
  (service-type
   (name 'qubes-qrexec-pam)
   (extensions
    (list (service-extension pam-root-service-type
                             qubes-qrexec-pam-services)))
   (default-value #f)
   (description "Install the PAM service used by qrexec-agent user sessions.")))

(define (qubes-acpi-shutdown-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-acpi-shutdown))
    (requirement '(root-file-system))
    (documentation "Handle Qubes ACPI power-button shutdown requests.")
    (start #~(make-forkexec-constructor
              (list #$(file-append acpid "/sbin/acpid")
                    "-f" "-n" "-S" "-l" "-c" "/etc/acpi/events")
              #:log-file "/var/log/qubes-acpid.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-acpi-shutdown-service-type
  (service-type
   (name 'qubes-acpi-shutdown)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-acpi-shutdown-shepherd-service)))
   (default-value #f)
   (description "Run acpid so dom0 qvm-shutdown can halt the VM.")))

(define %qubes-runtime-modules
  '((guix build utils)
    (ice-9 ftw)
    (ice-9 match)
    (ice-9 popen)
    (ice-9 textual-ports)
    (srfi srfi-1)
    (srfi srfi-13)))

(define-syntax qubes-vm-service-program
  (syntax-rules ()
    ((_ program-name body ...)
     (program-file
      program-name
      (with-imported-modules (source-module-closure %qubes-runtime-modules)
        #~(begin
            (use-modules (guix build utils)
                         (ice-9 ftw)
                         (ice-9 match)
                         (ice-9 popen)
                         (ice-9 textual-ports)
                         (srfi srfi-1)
                         (srfi srfi-13))

            (define modprobe #$(file-append kmod "/bin/modprobe"))
            (define mount "/run/current-system/profile/bin/mount")
            (define mountpoint "/run/current-system/profile/bin/mountpoint")
            (define mknod* "/run/current-system/profile/bin/mknod")
            (define qrexec-client-vm* "/run/current-system/profile/bin/qrexec-client-vm")
            (define qubesdb-read* "/run/current-system/profile/bin/qubesdb-read")
            (define qubesdb-write* "/run/current-system/profile/bin/qubesdb-write")
            (define kernel-modules-device "/dev/xvdd")
            (define kernel-modules-directory "/run/qubes-kernel-modules")

            (define (warn message)
              (display message (current-error-port))
              (newline (current-error-port)))

            (define (try-run* program . args)
              (false-if-exception
               (zero? (apply system* program args))))

            (define (run* program . args)
              (unless (apply try-run* program args)
                (warn (string-append "command failed: " program))
                (exit 1)))

            (define (exec* program . args)
              (apply execl program program args))

            (define (read-file path)
              (and (file-exists? path)
                   (call-with-input-file path get-string-all)))

            (define (string-trim-newlines text)
              (let loop ((end (string-length text)))
                (if (and (> end 0)
                         (memv (string-ref text (- end 1))
                               '(#\newline #\return)))
                    (loop (- end 1))
                    (substring text 0 end))))

            (define (command-output program . args)
              (let* ((port (apply open-pipe* OPEN_READ program args))
                     (text (get-string-all port))
                     (status (close-pipe port)))
                (and (zero? status)
                     (string-trim-newlines text))))

            (define (qubesdb-read path)
              (command-output qubesdb-read* path))

            (define (qubesdb-write path value)
              (try-run* qubesdb-write* path value))

            (define (regular-or-symlink? path)
              (let ((st (false-if-exception (lstat path))))
                (and st (memq (stat:type st) '(regular symlink)))))

            (define (same-directory-entry? left right)
              (let ((left-stat (false-if-exception (stat left)))
                    (right-stat (false-if-exception (stat right))))
                (and left-stat right-stat
                     (= (stat:dev left-stat) (stat:dev right-stat))
                     (= (stat:ino left-stat) (stat:ino right-stat)))))

            (define (same-link? target link)
              (let ((st (false-if-exception (lstat link))))
                (and st
                     (eq? 'symlink (stat:type st))
                     (string=? target (readlink link)))))

            (define (replace-symlink target link)
              (mkdir-p (dirname link))
              (cond
               ((same-link? target link) #t)
               ((regular-or-symlink? link)
                (delete-file link)
                (symlink target link))
               ((not (file-exists? link))
                (symlink target link))))

            (define (group-gid name)
              (let ((entry (false-if-exception (getgr name))))
                (and entry (vector-ref entry 2))))

            (define (profile-python-paths)
              (let* ((lib "/run/current-system/profile/lib")
                     (versions
                      (or (false-if-exception
                           (scandir lib
                                    (lambda (entry)
                                      (string-prefix? "python" entry))))
                          '())))
                (filter file-exists?
                        (map (lambda (version)
                               (string-append lib "/" version
                                              "/site-packages"))
                             versions))))

            (define (prepend-environment name entries)
              (unless (null? entries)
                (let ((current (getenv name)))
                  (setenv name
                          (string-append
                           (string-join entries ":")
                           (if (and current
                                    (not (string-null? current)))
                               (string-append ":" current)
                               ""))))))

            (define (kernel-release)
              (utsname:release (uname)))

            (define (kernel-modules-release-directory)
              (string-append kernel-modules-directory "/" (kernel-release)))

            (define (kernel-modules-mounted?)
              (try-run* mountpoint "-q" kernel-modules-directory))

            (define (kernel-modules-available?)
              (file-exists? (kernel-modules-release-directory)))

            (define (wait-for-path path attempts)
              (let loop ((attempt 0))
                (cond
                 ((file-exists? path) #t)
                 ((< attempt attempts)
                  (usleep 100000)
                  (loop (+ attempt 1)))
                 (else #f))))

            (define (kernel-modules-setup attempts)
              (mkdir-p kernel-modules-directory)
              (cond
               ((kernel-modules-available?) #t)
               ((wait-for-path kernel-modules-device attempts)
                (unless (kernel-modules-mounted?)
                  (unless (try-run* mount "-o" "ro"
                                    kernel-modules-device
                                    kernel-modules-directory)
                    (warn (string-append
                           "failed to mount Qubes dom0 kernel modules image: "
                           kernel-modules-device))
                    (exit 1)))
                (unless (kernel-modules-available?)
                  (warn (string-append
                         "Qubes dom0 kernel modules image is missing modules for "
                         (kernel-release)))
                  (exit 1)))
               (else
                (warn (string-append
                       "Qubes dom0 kernel modules device is not present: "
                       kernel-modules-device))
                #f)))

            (define (runtime-setup)
              (setenv "PATH"
                      (string-append
                       "/run/setuid-programs:"
                       "/run/current-system/profile/bin:"
                       "/run/current-system/profile/sbin"
                       (let ((path (getenv "PATH")))
                         (if path (string-append ":" path) ""))))
              (setenv "LINUX_MODULE_DIRECTORY"
                      kernel-modules-directory)
              (for-each
               (match-lambda
                 ((name . value)
                  (setenv name value)))
               '(("SSL_CERT_DIR" . "/etc/ssl/certs")
                 ("SSL_CERT_FILE" . "/etc/ssl/certs/ca-certificates.crt")
                 ("GIT_SSL_CAINFO" . "/etc/ssl/certs/ca-certificates.crt")
                 ("CURL_CA_BUNDLE" . "/etc/ssl/certs/ca-certificates.crt")))
              (let ((python-paths (profile-python-paths)))
                (prepend-environment "PYTHONPATH" python-paths)
                (prepend-environment "GUIX_PYTHONPATH" python-paths))
              (setenv "QREXEC_SERVICE_PATH"
                      (string-append
                       "/run/qubes-rpc:/usr/local/etc/qubes-rpc:/etc/qubes-rpc:"
                       "/run/current-system/profile/etc/qubes-rpc"))
              (setenv "QUBES_RPC_CONFIG_PATH"
                      (string-append
                       "/run/qubes/rpc-config:/usr/local/etc/qubes/rpc-config:"
                       "/etc/qubes/rpc-config:"
                       "/run/current-system/profile/etc/qubes/rpc-config"))
              (mkdir-p "/run/qubes")
              (mkdir-p "/run/qubes-service")
              (mkdir-p "/var/run")
              (mkdir-p "/var/log/qubes")
              (mkdir-p "/usr/local")
              (let ((gid (group-gid "qubes")))
                (when gid
                  (false-if-exception (chown "/run/qubes" -1 gid))))
              (chmod "/run/qubes" #o775)
              (unless (same-directory-entry? "/var/run" "/run")
                (replace-symlink "/run/qubes" "/var/run/qubes")
                (replace-symlink "/run/qubes-service" "/var/run/qubes-service")
                (replace-symlink "/run/qubes-service-environment"
                                 "/var/run/qubes-service-environment")))

            (define (misc-minor names)
              (let ((text (read-file "/proc/misc")))
                (and text
                     (any (lambda (line)
                            (let ((fields (string-tokenize line)))
                              (and (= (length fields) 2)
                                   (member (cadr fields) names)
                                   (car fields))))
                          (string-split text #\newline)))))

            (define (ensure-xen-node node names)
              (let ((path (string-append "/dev/xen/" node))
                    (minor (misc-minor names)))
                (when (and minor (not (file-exists? path)))
                  (try-run* mknod* path "c" "10" minor))))

            (define (xen-device-setup)
              (mkdir-p "/dev/xen")
              (mkdir-p "/proc/xen")
              (for-each (lambda (module)
                          (try-run* modprobe module))
                        '("xenfs" "xen_evtchn" "xen_gntalloc"
                          "xen_gntdev" "xen_privcmd"))
              (unless (try-run* mountpoint "-q" "/proc/xen")
                (try-run* mount "-t" "xenfs" "xenfs" "/proc/xen"))
              (for-each (lambda (spec)
                          (ensure-xen-node (car spec) (cdr spec)))
                        '(("xenbus" "xen/xenbus" "xenbus")
                          ("hypercall" "xen/hypercall" "hypercall")
                          ("privcmd" "xen/privcmd" "privcmd")
                          ("evtchn" "xen/evtchn" "evtchn")
                          ("gntdev" "xen/gntdev" "gntdev")
                          ("gntalloc" "xen/gntalloc" "gntalloc")))
              (when (and (not (file-exists? "/dev/xen/xenbus"))
                         (file-exists? "/proc/xen/xenbus"))
                (false-if-exception
                 (symlink "/proc/xen/xenbus" "/dev/xen/xenbus")))
              (let ((gid (group-gid "qubes")))
                (for-each (lambda (entry)
                            (let ((path (string-append "/dev/xen/" entry)))
                              (when gid
                                (false-if-exception (chown path -1 gid)))
                              (false-if-exception (chmod path #o660))))
                          (or (false-if-exception
                               (scandir "/dev/xen"
                                        (lambda (entry)
                                          (not (member entry '("." ".."))))))
                              '())))
              (let wait ((attempt 0))
                (when (and (< attempt 50)
                           (any (lambda (path)
                                  (not (file-exists? path)))
                                '("/dev/xen/xenbus" "/dev/xen/evtchn"
                                  "/dev/xen/gntalloc" "/dev/xen/gntdev"
                                  "/dev/xen/privcmd")))
                  (usleep 100000)
                  (wait (+ attempt 1)))))

            (define (prepare-service-runtime)
              (runtime-setup)
              (kernel-modules-setup 0)
              (xen-device-setup))

            (define (service-enabled? name)
              (file-exists? (string-append "/run/qubes-service/" name)))

            (define (wait-for-service-environment attempts)
              (let loop ((attempt attempts))
                (cond
                 ((file-exists? "/run/qubes-service-environment") #t)
                 ((zero? attempt) #f)
                 (else
                  (usleep 100000)
                  (loop (- attempt 1))))))

            body ...))))))

(define qubes-kvm-udev-rule
  (udev-rule "90-kvm.rules"
             "KERNEL==\"kvm\", GROUP=\"kvm\", MODE=\"0660\"\n"))

(define (qubes-udev-configurations-union subdirectory packages)
  (define build
    (with-imported-modules '((guix build union)
                             (guix build utils))
      #~(begin
          (use-modules (guix build union)
                       (guix build utils)
                       (srfi srfi-1))

          (define standard-locations
            '(#$(string-append "/lib/udev/" subdirectory)
              #$(string-append "/libexec/udev/" subdirectory)))

          (define (configuration-sub-directory directory)
            (find directory-exists?
                  (map (lambda (suffix)
                         (string-append directory suffix))
                       standard-locations)))

          (union-build #$output
                       (filter-map configuration-sub-directory '#$packages)))))

  (computed-file (string-append "qubes-udev-" subdirectory) build))

(define (qubes-udev-rules-union packages)
  (qubes-udev-configurations-union "rules.d" packages))

(define (qubes-udev-hardware-union packages)
  (qubes-udev-configurations-union "hwdb.d" packages))

(define qubes-udev.conf
  (computed-file "qubes-udev.conf"
                 #~(call-with-output-file #$output
                     (lambda (port)
                       (format port "udev_rules=\"/etc/udev/rules.d\"~%")))))

(define (qubes-udev-etc config)
  (let* ((udev (udev-configuration-udev config))
         (rules (udev-configuration-rules config))
         (hardware (udev-configuration-hardware config))
         (hardware-union (qubes-udev-hardware-union (cons* udev hardware)))
         (hwdb.bin
          (computed-file
           "qubes-udev-hwdb.bin"
           (with-imported-modules '((guix build utils))
             #~(begin
                 (use-modules (guix build utils))
                 (setenv "UDEV_HWDB_PATH" #$hardware-union)
                 (invoke #+(file-append udev "/bin/udevadm")
                         "hwdb" "--update" "-o" #$output))))))
    `(("udev"
       ,(file-union "qubes-udev"
                    `(("udev.conf" ,qubes-udev.conf)
                      ("rules.d"
                       ,(qubes-udev-rules-union
                         (cons* udev qubes-kvm-udev-rule rules)))
                      ("hwdb.bin" ,hwdb.bin)))))))

(define (qubes-udev-coldplug-program config)
  (let ((udev (udev-configuration-udev config)))
    (program-file
     "qubes-udev-coldplug"
     (with-imported-modules '()
       #~(begin
           (define udevadm #$(file-append udev "/bin/udevadm"))

           (define (wait-for-udev-control attempts)
             (cond
              ((file-exists? "/run/udev/control") #t)
              ((zero? attempts)
               (format #t "udevd control socket not ready; continuing Qubes boot~%")
               #f)
              (else
               (usleep 500000)
               (wait-for-udev-control (- attempts 1)))))

           (define (reap-child pid)
             (false-if-exception (waitpid pid)))

           (define (terminate-child pid)
             (false-if-exception (kill pid SIGTERM))
             (usleep 200000)
             (false-if-exception (kill pid SIGKILL))
             (reap-child pid))

           (define (run-udevadm/bounded seconds . args)
             (let ((pid (primitive-fork)))
               (if (= pid 0)
                   (begin
                     (apply execl udevadm udevadm args)
                     (exit 127))
                   (let wait ((remaining (* seconds 10)))
                     (let ((result (false-if-exception
                                    (waitpid pid WNOHANG))))
                       (cond
                        ((and result (= (car result) pid))
                         (let ((status (cdr result)))
                           (and (not (status:term-sig status))
                                (let ((exit-code (status:exit-val status)))
                                  (and exit-code (zero? exit-code))))))
                        ((zero? remaining)
                         (format #t "udevadm command timed out: ~s~%" args)
                         (terminate-child pid)
                         #f)
                        (else
                         (usleep 100000)
                         (wait (- remaining 1)))))))))

           (when (wait-for-udev-control 20)
             (run-udevadm/bounded
              5 "trigger" "--action=add" "--type=devices")
             (run-udevadm/bounded
              5 "trigger" "--action=add" "--type=subsystems")
             (run-udevadm/bounded 5 "settle" "--timeout=5")))))))

(define (qubes-udev-shepherd-service config)
  (let ((udev (udev-configuration-udev config)))
    (list
     (shepherd-service
      (provision '(udev))
      (requirement '(root-file-system sysctl qubes-kernel-modules))
      (documentation "Run eudev without making Qubes boot wait for global settle.")
      (start
       (with-imported-modules (source-module-closure
                               '((gnu build linux-boot)))
         #~(lambda ()
             (define udevd #$(file-append udev "/sbin/udevd"))

             (setenv "LINUX_MODULE_DIRECTORY"
                     "/run/qubes-kernel-modules")

             (let* ((kernel-release (utsname:release (uname)))
                    (linux-module-directory
                     (getenv "LINUX_MODULE_DIRECTORY"))
                    (directory
                     (string-append linux-module-directory "/"
                                    kernel-release))
                    (old-umask (umask #o022)))
               (when (file-exists? directory)
                 (make-static-device-nodes directory))
               (umask old-umask))

             (fork+exec-command
              (list udevd
                    #$@(if (udev-configuration-debug? config)
                           '("--debug")
                           '()))
              #:environment-variables
              (cons*
               (string-append "LINUX_MODULE_DIRECTORY="
                              (getenv "LINUX_MODULE_DIRECTORY"))
               (default-environment-variables))))))
      (stop #~(make-kill-destructor))
      (respawn? #f)
      (modules `((gnu build linux-boot)
                 ,@%default-modules)))
     (shepherd-service
      (provision '(qubes-udev-coldplug))
      (requirement '(udev))
      (documentation "Trigger Qubes udev coldplug without blocking udev readiness.")
      (start #~(make-forkexec-constructor
                (list #$(qubes-udev-coldplug-program config))
                #:log-file "/var/log/qubes-udev-coldplug.log"))
      (stop #~(make-kill-destructor))
      (respawn? #f)))))

(define qubes-udev-service-type
    (service-type
     (name 'udev)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-udev-shepherd-service)
          (service-extension etc-service-type qubes-udev-etc)))
   (compose concatenate)
   (extend (lambda (config rules)
             (udev-configuration
              (inherit config)
              (rules (append (udev-configuration-rules config)
                             rules)))))
   (default-value (udev-configuration))
   (description "Run eudev with Qubes boot readiness semantics.")))

(define (run-one-shot-gexp program log-file best-effort?)
  #~(lambda _
      (define (status-success? status)
        (and (not (status:term-sig status))
             (let ((exit-code (status:exit-val status)))
               (and exit-code (zero? exit-code)))))

      (define (run/logged)
        (let ((pid (primitive-fork)))
          (if (= pid 0)
              (begin
                (let ((port (open-file #$log-file "a")))
                  (dup2 (fileno port) 1)
                  (dup2 (fileno port) 2)
                  (close-port port))
                (execl #$program #$program))
              (cdr (waitpid pid)))))

      (let ((status (run/logged)))
        (if #$best-effort?
            #t
            (status-success? status)))))

(define* (one-shot-service name requirements program log-file
                           #:key (best-effort? #f))
  (shepherd-service
   (provision (list name))
   (requirement requirements)
   (one-shot? #t)
   (respawn? #f)
   (documentation (string-append "Run " (symbol->string name) " once."))
   (start (run-one-shot-gexp program log-file best-effort?))
   (stop #~(const #f))))

(define (qubes-kernel-modules-program)
  (qubes-vm-service-program
   "qubes-kernel-modules"
   (runtime-setup)
   (kernel-modules-setup 300)))

(define (qubes-kernel-modules-shepherd-service _)
  (list
   (one-shot-service
    'qubes-kernel-modules
    '(root-file-system)
    (qubes-kernel-modules-program)
    "/var/log/qubes-kernel-modules.log")))

(define qubes-kernel-modules-service-type
  (service-type
   (name 'qubes-kernel-modules)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-kernel-modules-shepherd-service)))
   (default-value #f)
   (description "Mount the Qubes dom0-provided kernel modules image.")))

(define (qubes-sysctl-settings-file settings)
  (plain-file "qubes-sysctl-settings.scm"
              (object->string settings)))

(define (qubes-sysctl-program settings)
  (let ((settings-file (qubes-sysctl-settings-file settings)))
    (qubes-vm-service-program
     "qubes-sysctl"
     (define sysctl-settings
       (call-with-input-file #$settings-file read))

     (define (sysctl-key->path key)
       (string-append
        "/proc/sys/"
        (list->string
         (map (lambda (char)
                (if (char=? char #\.) #\/ char))
              (string->list key)))))

     (define (write-sysctl setting)
       (let* ((key (car setting))
              (value (cdr setting))
              (path (sysctl-key->path key)))
         (unless (file-exists? path)
           (warn (string-append "sysctl path is missing: " path))
           (exit 1))
         (catch #t
           (lambda ()
             (call-with-output-file path
               (lambda (port)
                 (display value port)
                 (newline port))))
           (lambda (key . args)
             (warn (string-append "failed to write sysctl path: " path))
             (exit 1)))))

     (for-each write-sysctl sysctl-settings))))

(define (qubes-sysctl-shepherd-service config)
  (list
   (one-shot-service
    'sysctl
    '(root-file-system)
    (qubes-sysctl-program (sysctl-configuration-settings config))
    "/var/log/sysctl.log")))

(define qubes-sysctl-service-type
  (service-type
   (name 'sysctl)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-sysctl-shepherd-service)))
   (compose concatenate)
   (extend (lambda (config settings)
             (sysctl-configuration
              (inherit config)
              (settings (append (sysctl-configuration-settings config)
                                settings)))))
   (default-value (sysctl-configuration))
   (description "Apply kernel sysctl settings with a Qubes-local Scheme helper.")))

(define (qubes-loopback-program)
  (qubes-vm-service-program
   "qubes-loopback"
   (define ip "/run/current-system/profile/sbin/ip")

   (let wait ((attempt 0))
     (cond
      ((file-exists? "/sys/class/net/lo")
       (run* ip "link" "set" "lo" "up")
       (exit 0))
      ((< attempt 50)
       (usleep 100000)
       (wait (+ attempt 1)))
      (else
       (warn "loopback network device did not appear")
       (exit 1))))))

(define (qubes-loopback-shepherd-service _)
  (list
   (one-shot-service
    'qubes-loopback
    '(root-file-system)
    (qubes-loopback-program)
    "/var/log/qubes-loopback.log")))

(define qubes-loopback-service-type
  (service-type
   (name 'qubes-loopback)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-loopback-shepherd-service)))
   (default-value #f)
   (description "Bring up the loopback interface without generic static networking.")))

(define %qubes-network-sysctl-settings
  '(("ipv4" "accept_source_route" . "0")
    ("ipv4" "accept_redirects" . "0")
    ("ipv4" "secure_redirects" . "0")
    ("ipv4" "send_redirects" . "0")
    ("ipv4" "drop_unicast_in_l2_multicast" . "1")
    ("ipv6" "accept_source_route" . "-1")
    ("ipv6" "accept_redirects" . "0")
    ("ipv6" "accept_ra" . "0")
    ("ipv6" "accept_dad" . "0")
    ("ipv6" "autoconf" . "0")
    ("ipv6" "drop_unicast_in_l2_multicast" . "1")))

(define (qubes-network-sysctl-program)
  (qubes-vm-service-program
   "qubes-network-sysctl"
   (define network-sysctl-settings
     '(("ipv4" "accept_source_route" . "0")
       ("ipv4" "accept_redirects" . "0")
       ("ipv4" "secure_redirects" . "0")
       ("ipv4" "send_redirects" . "0")
       ("ipv4" "drop_unicast_in_l2_multicast" . "1")
       ("ipv6" "accept_source_route" . "-1")
       ("ipv6" "accept_redirects" . "0")
       ("ipv6" "accept_ra" . "0")
       ("ipv6" "accept_dad" . "0")
       ("ipv6" "autoconf" . "0")
       ("ipv6" "drop_unicast_in_l2_multicast" . "1")))

   (define (interface-names family)
     (let ((directory (string-append "/proc/sys/net/" family "/conf")))
       (or (false-if-exception
            (scandir directory
                     (lambda (entry)
                       (not (member entry '("." ".."))))))
           '())))

   (define (write-sysctl path value)
     (when (file-exists? path)
       (false-if-exception
        (call-with-output-file path
          (lambda (port)
            (display value port))))))

   (define (apply-setting setting)
     (let ((family (car setting))
           (name (cadr setting))
           (value (cddr setting)))
       (for-each
        (lambda (interface)
          (write-sysctl
           (string-append "/proc/sys/net/" family "/conf/"
                          interface "/" name)
           value))
        (interface-names family))))

   (for-each apply-setting network-sysctl-settings)))

(define (qubes-network-sysctl-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network-sysctl
    '(root-file-system qubes-loopback)
    (qubes-network-sysctl-program)
    "/var/log/qubes-network-sysctl.log")))

(define qubes-network-sysctl-service-type
  (service-type
   (name 'qubes-network-sysctl)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-sysctl-shepherd-service)))
   (default-value #f)
   (description "Apply Qubes network sysctl settings without early wildcard sysctl.")))

(define (qubes-db-program)
  (qubes-vm-service-program
   "qubes-db"
   (prepare-service-runtime)
   (exec* "/run/current-system/profile/bin/qubesdb-daemon" "0")))

(define (qubes-db-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-db))
    (requirement '(root-file-system qubes-kernel-modules))
    (documentation "Run the QubesDB VM daemon.")
    (start #~(make-forkexec-constructor
              (list #$(qubes-db-program))
              #:log-file "/var/log/qubes-db.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-db-service-type
  (service-type
   (name 'qubes-db)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-db-shepherd-service)))
   (default-value #f)
   (description "Run QubesDB inside a Qubes VM.")))

(define (qubes-sysinit-program)
  (qubes-vm-service-program
   "qubes-sysinit"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/init/qubes-sysinit.sh")))

(define (qubes-sysinit-shepherd-service _)
  (list
   (one-shot-service
    'qubes-sysinit
    '(qubes-db)
    (qubes-sysinit-program)
    "/var/log/qubes-sysinit.log")))

(define qubes-sysinit-service-type
  (service-type
   (name 'qubes-sysinit)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-sysinit-shepherd-service)))
   (default-value #f)
   (description "Run Qubes VM sysinit.")))

(define-record-type* <qubes-meminfo-writer-configuration>
  qubes-meminfo-writer-configuration make-qubes-meminfo-writer-configuration
  qubes-meminfo-writer-configuration?
  (package qubes-meminfo-writer-configuration-package
           (default qubes-vm-utils))
  (threshold qubes-meminfo-writer-configuration-threshold
             (default 30000))
  (delay qubes-meminfo-writer-configuration-delay
         (default 100000))
  (pid-file qubes-meminfo-writer-configuration-pid-file
            (default "/var/run/meminfo-writer.pid")))

(define (qubes-meminfo-writer-program config)
  (let ((meminfo-writer
         (file-append (qubes-meminfo-writer-configuration-package config)
                      "/bin/meminfo-writer"))
        (threshold
         (number->string
          (qubes-meminfo-writer-configuration-threshold config)))
        (delay
         (number->string
          (qubes-meminfo-writer-configuration-delay config)))
        (pid-file
         (qubes-meminfo-writer-configuration-pid-file config)))
    (qubes-vm-service-program
     "qubes-meminfo-writer"
     (define pidfile #$pid-file)

     (define (read-pid path)
       (and (file-exists? path)
            (let ((text (call-with-input-file path get-string-all)))
              (string->number (string-trim-both text)))))

     (prepare-service-runtime)

     (unless (service-enabled? "meminfo-writer")
       (display "meminfo-writer service flag not present; exiting\n")
       (exit 0))

     (when (file-exists? pidfile)
       (delete-file pidfile))
     (unless (zero? (system* #$meminfo-writer
                             #$threshold #$delay pidfile))
       (warn "meminfo-writer failed to start")
       (exit 1))

     (let wait-for-pid ((attempt 0))
       (let ((pid (read-pid pidfile)))
         (cond
          ((and pid (> pid 1))
           (sigaction SIGTERM
             (lambda _
               (false-if-exception (kill pid SIGTERM))
               (false-if-exception (delete-file pidfile))
               (exit 0)))
           (sigaction SIGINT
             (lambda _
               (false-if-exception (kill pid SIGTERM))
               (false-if-exception (delete-file pidfile))
               (exit 0)))
           (let loop ()
             (if (false-if-exception (kill pid 0))
                 (begin
                   (sleep 60)
                   (loop))
                 (begin
                   (false-if-exception (delete-file pidfile))
                   (exit 1)))))
          ((< attempt 50)
           (usleep 100000)
           (wait-for-pid (+ attempt 1)))
          (else
           (warn "meminfo-writer did not create a valid pid file")
           (exit 1))))))))

(define (qubes-meminfo-writer-shepherd-service config)
  (list
   (shepherd-service
    (provision '(qubes-meminfo-writer))
    (requirement '(qubes-sysinit))
    (documentation "Run the Qubes memory information reporter.")
    (respawn? #f)
    (start #~(make-forkexec-constructor
              (list #$(qubes-meminfo-writer-program config))
              #:log-file "/var/log/qubes-meminfo-writer.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-meminfo-writer-service-type
  (service-type
   (name 'qubes-meminfo-writer)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-meminfo-writer-shepherd-service)))
   (default-value (qubes-meminfo-writer-configuration))
   (description "Run Qubes memory usage reporting for dom0 ballooning.")))

(define (qubes-network-uplink-program)
  (qubes-vm-service-program
   "qubes-network-uplink"
   (define ip "/run/current-system/profile/sbin/ip")
   (define network-sysctl-settings
     '(("ipv4" "accept_source_route" . "0")
       ("ipv4" "accept_redirects" . "0")
       ("ipv4" "secure_redirects" . "0")
       ("ipv4" "send_redirects" . "0")
       ("ipv4" "drop_unicast_in_l2_multicast" . "1")
       ("ipv6" "accept_source_route" . "-1")
       ("ipv6" "accept_redirects" . "0")
       ("ipv6" "accept_ra" . "0")
       ("ipv6" "accept_dad" . "0")
       ("ipv6" "autoconf" . "0")
       ("ipv6" "drop_unicast_in_l2_multicast" . "1")))

   (define (iface-mac iface)
     (and iface
          (read-file (string-append "/sys/class/net/" iface "/address"))))

   (define (iface-for-mac mac)
     (and mac
          (any (lambda (iface)
                 (let ((address (iface-mac iface)))
                   (and address
                        (string-ci=? (string-trim-newlines address) mac)
                        iface)))
               (or (false-if-exception
                    (scandir "/sys/class/net"
                             (lambda (entry)
                               (not (member entry '("." ".."))))))
                   '()))))

   (define (qubes-managed-iface)
     (let ((mac (qubesdb-read "/qubes-mac")))
       (and mac
            (begin
              (unless (file-exists? "/sys/module/xen_netfront")
                (try-run* modprobe "xen-netfront"))
              (or (iface-for-mac mac)
                  (and (file-exists? "/sys/class/net/eth0")
                       "eth0"))))))

     (define (apply-interface-sysctl iface)
       (for-each
        (lambda (setting)
          (let ((family (car setting))
                (name (cadr setting))
                (value (cddr setting)))
            (write-sysctl
             (string-append "/proc/sys/net/" family "/conf/" iface "/" name)
             value)))
        network-sysctl-settings))

   (define (write-sysctl path value)
     (when (file-exists? path)
       (false-if-exception
        (call-with-output-file path
          (lambda (port)
            (display value port))))))

     (prepare-service-runtime)
     (try-run* ip "link" "set" "lo" "up")
     (let wait ((attempt 0))
       (let ((iface (qubes-managed-iface)))
         (cond
          (iface
           (apply-interface-sysctl iface)
           (exec* "/usr/lib/qubes/setup-ip" "add" iface))
          ((< attempt 300)
           (usleep 100000)
           (wait (+ attempt 1)))
          (else
           (display "No Qubes managed network interface found\n")
           (exit 0)))))))

(define (qubes-network-uplink-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network-uplink
    '(qubes-sysinit sysctl qubes-network-sysctl)
    (qubes-network-uplink-program)
    "/var/log/qubes-network-uplink.log")))

(define qubes-network-uplink-service-type
  (service-type
   (name 'qubes-network-uplink)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-uplink-shepherd-service)))
   (default-value #f)
   (description "Configure the Qubes-provided VM network uplink.")))

(define (qubes-network-program)
  (qubes-vm-service-program
   "qubes-network"
   (define dnat-helper "/usr/lib/qubes/qubes-setup-dnat-to-ns")

   (define (write-required-file path value)
     (unless (file-exists? path)
       (warn (string-append "required network control file is missing: " path))
       (exit 1))
     (catch #t
       (lambda ()
         (call-with-output-file path
           (lambda (port)
             (display value port)
             (newline port))))
       (lambda (key . args)
         (warn (string-append "failed to write network control file: " path))
         (exit 1))))

   (define (write-optional-file path value)
     (when (file-exists? path)
       (false-if-exception
        (call-with-output-file path
          (lambda (port)
            (display value port)
            (newline port))))))

   (define (module-loaded? name)
     (file-exists? (string-append "/sys/module/" name)))

   (define (network-backend-loaded?)
     (or (module-loaded? "netbk")
         (module-loaded? "xen_netback")))

   (define (load-network-backend)
     (unless (or (network-backend-loaded?)
                 (try-run* modprobe "netbk")
                 (try-run* modprobe "xen-netback")
                 (network-backend-loaded?))
       (warn "could not load Xen network backend module")
       (exit 1)))

   (prepare-service-runtime)
   (wait-for-service-environment 600)
   (cond
    ((not (service-enabled? "qubes-network"))
     (display "qubes-network service flag not present; network backend inactive\n")
     (exit 0))
    ((string-null? (or (qubesdb-read "/qubes-netvm-network") ""))
     (display "No Qubes downstream network configured for this VM\n")
     (exit 0))
    (else
     (load-network-backend)
     (run* dnat-helper)
     (write-required-file "/proc/sys/net/ipv4/ip_forward" "1")
     (unless (string-null? (or (qubesdb-read "/qubes-netvm-gateway6") ""))
       (write-optional-file "/proc/sys/net/ipv6/conf/all/forwarding" "1"))))))

(define (qubes-network-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network
    '(qubes-sysinit sysctl qubes-network-sysctl qubes-network-uplink)
    (qubes-network-program)
    "/var/log/qubes-network.log")))

(define qubes-network-service-type
  (service-type
   (name 'qubes-network)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-shepherd-service)))
   (default-value #f)
   (description "Configure the Qubes network backend role for NetVMs.")))

(define (qubes-feature-advertisement-program)
  (qubes-vm-service-program
   "qubes-feature-advertisement"
   (define supported-services
     '("updates-proxy-setup" "qubes-network"))

   (define (request-feature name value)
     (unless (qubesdb-write (string-append "/features-request/" name) value)
       (warn (string-append "failed to write Qubes feature request: " name))
       (exit 1)))

   (prepare-service-runtime)
   (for-each
    (lambda (service)
      (request-feature (string-append "supported-service." service) "1"))
    supported-services)
   (unless (try-run* qrexec-client-vm* "dom0" "qubes.FeaturesRequest")
     (warn "failed to commit Qubes feature requests")
     (exit 1))))

(define (qubes-feature-advertisement-shepherd-service _)
  (list
   (one-shot-service
    'qubes-feature-advertisement
    '(qubes-qrexec-agent)
    (qubes-feature-advertisement-program)
    "/var/log/qubes-feature-advertisement.log")))

(define qubes-feature-advertisement-service-type
  (service-type
   (name 'qubes-feature-advertisement)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-feature-advertisement-shepherd-service)))
   (default-value #f)
   (description "Advertise Qubes services implemented by native Guix services.")))

(define (qubes-updates-proxy-forwarder-program)
  (qubes-vm-service-program
   "qubes-updates-proxy-forwarder"
   (runtime-setup)
   (wait-for-service-environment 600)
   (cond
    ((not (service-enabled? "updates-proxy-setup"))
     (display "updates-proxy-setup service flag not present; forwarder inactive\n")
     (exit 0))
    ((service-enabled? "qubes-updates-proxy")
     (display "qubes-updates-proxy enabled locally; not forwarding to avoid loops\n")
     (exit 0))
    (else
     (exec* "/run/current-system/profile/bin/socat"
            "TCP-LISTEN:8082,bind=127.0.0.1,reuseaddr,fork"
            "EXEC:/usr/lib/qubes/guix-updates-proxy-forwarder")))))

(define (qubes-updates-proxy-forwarder-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-updates-proxy-forwarder))
    (requirement '(qubes-sysinit qubes-loopback))
    (documentation "Forward 127.0.0.1:8082 to Qubes UpdatesProxy RPC.")
    (respawn? #f)
    (start #~(make-forkexec-constructor
              (list #$(qubes-updates-proxy-forwarder-program))
              #:log-file "/var/log/qubes-updates-proxy-forwarder.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-updates-proxy-forwarder-service-type
  (service-type
   (name 'qubes-updates-proxy-forwarder)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-updates-proxy-forwarder-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes updates proxy forwarder socket service.")))

(define (qubes-mount-dirs-program)
  (qubes-vm-service-program
   "qubes-mount-dirs"
   (define findmnt "/run/current-system/profile/bin/findmnt")
   (define mount-dirs "/usr/lib/qubes/init/mount-dirs.sh")
   (define fstab-entry
     "/dev/xvdb /rw auto noauto,defaults,discard,nosuid,nodev 1 2\n")

   (define (mounted? path)
     (try-run* findmnt "-rn" path))

   (define (fstab-has-rw?)
     (let ((text (read-file "/etc/fstab")))
       (and text
            (any (lambda (line)
	                   (let ((fields (string-tokenize line)))
	                     (and (>= (length fields) 2)
                                  (not (string-prefix? "#" (car fields)))
	                          (string=? (cadr fields) "/rw"))))
                 (string-split text #\newline)))))

   (define (append-fstab-entry)
     (let ((port (open-file "/etc/fstab" "a")))
       (display fstab-entry port)
       (close-port port)))

   (define (repair-fstab-entry)
     (when (and (or (file-exists? "/dev/xvdb")
                    (mounted? "/rw"))
                (not (fstab-has-rw?)))
       (append-fstab-entry)))

   (define (wait-for-rw-device)
     (when (string=? (or (qubesdb-read "/qubes-vm-persistence") "")
                     "rw-only")
       (let loop ((attempt 0))
         (cond
          ((file-exists? "/dev/xvdb") #t)
          ((< attempt 300)
           (usleep 100000)
           (loop (+ attempt 1)))
          (else
           (warn "Qubes private-volume device /dev/xvdb did not appear")
           (exit 1))))))

	   (prepare-service-runtime)
	   (wait-for-rw-device)
	   (repair-fstab-entry)
	   (when (and (mounted? "/rw")
	              (mounted? "/home")
	              (mounted? "/usr/local"))
	     (display "Qubes private directories already mounted\n")
	     (exit 0))
	   (run* mount-dirs)
	   (repair-fstab-entry)))

(define (qubes-mount-dirs-shepherd-service _)
  (list
   (one-shot-service
    'qubes-mount-dirs
    '(qubes-sysinit)
    (qubes-mount-dirs-program)
    "/var/log/qubes-mount-dirs.log")))

(define qubes-mount-dirs-service-type
  (service-type
   (name 'qubes-mount-dirs)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-mount-dirs-shepherd-service)))
   (default-value #f)
   (description "Mount Qubes persistent directories such as /rw, /home, and /usr/local.")))

(define (qubes-bind-dirs-program)
  (qubes-vm-service-program
   "qubes-bind-dirs"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/init/bind-dirs.sh")))

(define (qubes-bind-dirs-shepherd-service _)
  (list
   (one-shot-service
    'qubes-bind-dirs
    '(qubes-mount-dirs)
    (qubes-bind-dirs-program)
    "/var/log/qubes-bind-dirs.log")))

(define qubes-bind-dirs-service-type
  (service-type
   (name 'qubes-bind-dirs)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-bind-dirs-shepherd-service)))
   (default-value #f)
   (description "Apply Qubes bind-dirs configuration.")))

(define (qubes-misc-post-program)
  (qubes-vm-service-program
   "qubes-misc-post"
   (prepare-service-runtime)
   (let ((status (system* "/usr/lib/qubes/init/misc-post.sh")))
     (unless (zero? status)
       (warn (string-append "qubes-misc-post exited with status "
                            (number->string status)))))
   (exit 0)))

(define (qubes-misc-post-shepherd-service _)
  (list
   (one-shot-service
    'qubes-misc-post
    '(qubes-bind-dirs)
    (qubes-misc-post-program)
    "/var/log/qubes-misc-post.log"
    #:best-effort? #t)))

(define qubes-misc-post-service-type
  (service-type
   (name 'qubes-misc-post)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-misc-post-shepherd-service)))
   (default-value #f)
   (description "Run late Qubes VM setup.")))

(define (qubes-qrexec-agent-program)
  (qubes-vm-service-program
   "qubes-qrexec-agent"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/qrexec-agent")))

(define (qubes-qrexec-agent-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-qrexec-agent))
    (requirement '(qubes-bind-dirs))
    (documentation "Run the Qubes qrexec agent.")
    (start #~(make-forkexec-constructor
              (list #$(qubes-qrexec-agent-program))
              #:log-file "/var/log/qubes-qrexec-agent.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-qrexec-agent-service-type
  (service-type
   (name 'qubes-qrexec-agent)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-qrexec-agent-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes qrexec agent.")))

(define (qubes-gui-agent-program)
  (qubes-vm-service-program
   "qubes-gui-agent"
   (define (read-service-environment)
     (let ((text (read-file "/run/qubes-service-environment")))
       (if text
           (filter-map
            (lambda (line)
              (let ((index (string-index line #\=)))
                (and index
                     (cons (substring line 0 index)
                           (substring line (+ index 1))))))
            (string-split text #\newline))
           '())))

   (define (environment-ref entries key default)
     (match (assoc key entries)
       ((_ . value) value)
       (_ default)))

   (prepare-service-runtime)
   (unless (string=? (or (command-output qubesdb-read*
                                         "/qubes-gui-enabled")
                         "True")
                     "True")
     (exit 0))
   (setenv "DISPLAY" ":0")
   (run* "/usr/lib/qubes/qubes-gui-agent-pre.sh")
   (let* ((entries (read-service-environment))
          (display (environment-ref entries "DISPLAY" ":0"))
          (gui-opts (environment-ref entries "GUI_OPTS" "")))
     (setenv "DISPLAY" display)
     (setenv "GUI_OPTS" gui-opts)
     (apply execl
            "/run/current-system/profile/bin/qubes-gui"
            "/run/current-system/profile/bin/qubes-gui"
            (string-tokenize gui-opts)))))

(define (qubes-gui-agent-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-gui-agent))
    (requirement '(user-processes qubes-bind-dirs qubes-qrexec-agent))
    (documentation "Run the Qubes GUI agent.")
    (start #~(make-forkexec-constructor
              (list #$(qubes-gui-agent-program))
              #:log-file "/var/log/qubes-gui-agent.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-gui-agent-service-type
  (service-type
   (name 'qubes-gui-agent)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-gui-agent-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes GUI agent.")))

(define %qubes-vm-headless-services
  (list (service qubes-vm-compat-service-type)
        (service qubes-kernel-modules-service-type)
        (service qubes-udev-service-type
                 (udev-configuration
                  (rules '())))
        (service qubes-loopback-service-type)
        (service qubes-qrexec-pam-service-type)
        (service qubes-acpi-shutdown-service-type)
        (service qubes-db-service-type)
        (service qubes-sysinit-service-type)
        (service qubes-meminfo-writer-service-type)
        (service qubes-network-sysctl-service-type)
        (service qubes-network-uplink-service-type)
        (service qubes-network-service-type)
        (service qubes-updates-proxy-forwarder-service-type)
        (service qubes-mount-dirs-service-type)
        (service qubes-bind-dirs-service-type)
        (service qubes-misc-post-service-type)
        (service qubes-qrexec-agent-service-type)
        (service qubes-feature-advertisement-service-type)))

(define %qubes-vm-gui-services
  (append %qubes-vm-headless-services
          (list (service qubes-gui-agent-service-type))))

;;; Qubes TemplateVM operating-system definition
;; SPDX-License-Identifier: GPL-3.0-or-later

(define %qubes-omitted-base-service-types
  '(agetty
    console-fonts
    etc-bashrc-d
    login
    log-cleanup
    log-rotation
    mingetty
    nscd
    shepherd-timer
    shepherd-transient
    static-networking
    sysctl
    udev
    virtual-terminal))

(define %qubes-kernel-sysctl-settings
  '(("kernel.threads-max" . "51200")))

(define %qubes-base-services
  ;; Keep the daemon usable in ordinary networked AppVMs.  The Qubes updates
  ;; proxy forwarder is gated by the updates-proxy-setup service flag; forcing
  ;; guix-daemon through 127.0.0.1:8082 here breaks substitute downloads when
  ;; that flag is absent.
  %base-services)

(define %qubes-sysctl-service
  (service qubes-sysctl-service-type
           (sysctl-configuration
            (settings (append %qubes-kernel-sysctl-settings
                              %default-sysctl-settings)))))

(define %qubes-minimal-base-services
  (filter (lambda (service)
            (not (memq (service-type-name (service-kind service))
                       %qubes-omitted-base-service-types)))
          %qubes-base-services))

(define* (qubes-dom0-kernel-bootloader-config _config _entries
                                              #:key
                                              #:allow-other-keys)
  (define (entry->gexp entry)
    (let ((label (menu-entry-label entry))
          (linux (menu-entry-linux entry))
          (initrd (menu-entry-initrd entry))
          (arguments (menu-entry-linux-arguments entry)))
      #~(begin
          ;; guix system init copies the closure of the bootloader config.  The
          ;; comments below deliberately reference the generated boot entry so
          ;; the native root image receives the full system closure even though
          ;; Qubes dom0 provides the actual VM kernel.
          (format port "# entry: ~a\n# linux: ~a\n# initrd: ~a\n# args:"
                  #$label #$linux #$initrd)
          (for-each (lambda (argument)
                      (format port " ~a" argument))
                    (list #$@arguments))
          (newline port))))

  (computed-file
   "qubes-dom0-kernel.cfg"
   #~(call-with-output-file #$output
       (lambda (port)
         (display "Qubes dom0 supplies the VM kernel; no guest bootloader is installed.\n"
                  port)
         #$@(map entry->gexp _entries)))
   #:options '(#:local-build? #t
               #:substitutable? #f)))

(define qubes-dom0-kernel-bootloader
  (bootloader
   (name 'qubes-dom0-kernel)
   ;; Keep this to an already-needed package so the bootloader record does not
   ;; pull GRUB, QEMU, or firmware into a template that never boots itself.
   (package bash-minimal)
   (installer #~(lambda (_bootloader _device _mount-point) #t))
   (configuration-file "/boot/qubes-dom0-kernel.cfg")
   (configuration-file-generator qubes-dom0-kernel-bootloader-config)))

(define xterm-with-desktop-entry
  (package
    (inherit xterm)
    (arguments
     (substitute-keyword-arguments (package-arguments xterm)
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            (add-after 'install 'install-desktop-entry
              (lambda _
                (let ((applications
                       (string-append #$output "/share/applications")))
                  (mkdir-p applications)
                  (call-with-output-file
                      (string-append applications "/xterm.desktop")
                    (lambda (port)
                      (format port
                              "[Desktop Entry]
Name=XTerm
Comment=standard terminal emulator for the X window system
Exec=xterm -fa Monospace -fs 10
Terminal=false
Type=Application
Encoding=UTF-8
Icon=~a/share/pixmaps/xterm-color_48x48.xpm
Categories=System;TerminalEmulator;
Keywords=shell;prompt;command;commandline;cmd;
StartupWMClass=XTerm
" #$output))))))))))))

(define %qubes-common-packages
  (append %qubes-vm-gui-packages
          (list acpid bash conntrack-tools coreutils diffutils e2fsprogs
                findutils font-alias font-misc-misc
                gawk git glibc grep guile-3.0 guix gzip inetutils
                iproute kmod curl
                nftables nss-certs procps python python-dbus python-pygobject
                python-pyxdg sed setxkbmap shadow socat sudo tar util-linux zstd
                xdpyinfo xev xinput xinit xmodmap xprop xrandr xrdb
                xsetroot xwininfo
                dbus xorg-server xterm-with-desktop-entry)))

(define %qubes-normal-desktop-packages
  ;; Keep the normal template intentionally small, but provide the basic
  ;; application classes Qubes desktop tests and users expect to discover:
  ;; terminal, file manager, text editor, and document viewer.
  (list evince mousepad thunar xfce4-terminal))

(define (qubes-variant-packages variant)
  (case variant
    ((minimal)
     %qubes-common-packages)
    ((normal)
     (append %qubes-normal-desktop-packages
             %qubes-common-packages))
    (else
     (error "unsupported Qubes Guix template variant" variant))))

(define %qubes-privileged-programs
  (cons (privileged-program
         (program (file-append qubes-vm-core "/lib/qubes/qfile-unpacker"))
         (setuid? #t))
        %default-privileged-programs))

(define* (qubes-template-operating-system #:key (variant 'normal))
  (operating-system
    (host-name (case variant
                 ((minimal) "guix-minimal-qubes")
                 (else "guix-qubes")))
    (timezone "Etc/UTC")
    (locale "en_US.utf8")

    ;; Qubes normally supplies the VM kernel from dom0. A bootloader is still
    ;; required by the Guix record, but build-native-rootfs.sh uses --no-bootloader.
    (bootloader
     (bootloader-configuration
      (bootloader qubes-dom0-kernel-bootloader)
      (targets '("/dev/xvda"))))
    (kernel qubes-dom0-kernel)
    (initrd-modules '())

    (kernel-arguments
     (append '("console=hvc0" "panic=1")
             %default-kernel-arguments))

    (file-systems
     (cons* (file-system
              (mount-point "/")
              (device (file-system-label "guix-root"))
              (type "ext4"))
            %base-file-systems))
    (swap-devices
     (list (swap-space
            (target "/dev/xvdc1"))))

    (users
     (cons* (user-account
              (name "user")
              (comment "Qubes user")
              (group "users")
              (supplementary-groups '("wheel" "netdev" "audio" "video"
                                      "qubes")))
            %base-user-accounts))

    (groups
     (cons* (user-group (name "qubes"))
            %base-groups))

    (packages (qubes-variant-packages variant))

    (privileged-programs %qubes-privileged-programs)
    (sudoers-file
     (plain-file "sudoers"
                 "root ALL=(ALL) ALL
%wheel ALL=(ALL) NOPASSWD:ALL
user ALL=(ALL) NOPASSWD:ALL
"))

    (services
     (append (list (service dbus-root-service-type))
             %qubes-vm-gui-services
             (list %qubes-sysctl-service)
             %qubes-minimal-base-services))

    (name-service-switch %mdns-host-lookup-nss)))

(define (qubes-template-variant)
  (let ((value (or (getenv "QUBES_GUIX_TEMPLATE_VARIANT")
                   (false-if-exception
                    (call-with-input-file "/etc/qubes-guix-template-variant"
                      read-line))
                   "normal")))
    (match value
      ("normal" 'normal)
      ("minimal" 'minimal)
      (_ (error "unsupported Qubes Guix template variant" value)))))

(qubes-template-operating-system #:variant (qubes-template-variant))
