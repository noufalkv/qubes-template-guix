#!/run/current-system/profile/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guix helper for Qubes template repository qrexec queries.

The stock qvm-template-repo-query helper delegates rpm-md repository access to
DNF.  Native Guix System templates do not ship DNF, but qvm-template only needs
template repo query rows and raw RPM download bytes from the UpdateVM.  This
helper implements that narrow rpm-md path with Python, curl, and zstd.
"""

import configparser
import fnmatch
import gzip
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET


REPO_NS = "http://linux.duke.edu/metadata/repo"
COMMON_NS = "http://linux.duke.edu/metadata/common"
RPM_NS = "http://linux.duke.edu/metadata/rpm"
PACKAGE_PREFIX = "qubes-template-"


def error(message):
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def curl_bytes(url):
    return subprocess.check_output(
        ["curl", "--fail", "--silent", "--show-error", "--location", url]
    )


def curl_to_stdout(url):
    return subprocess.call(
        ["curl", "--fail", "--silent", "--show-error", "--location",
         "-o", "-", url]
    )


def expand_repo_value(value, releasever):
    return (
        value.replace("${releasever}", releasever)
        .replace("$releasever", releasever)
        .replace("${basearch}", "x86_64")
        .replace("$basearch", "x86_64")
    )


def parse_payload(stdin_text):
    options = []
    spec = "*"
    repo_lines = []
    in_repo_config = False

    for line in stdin_text.splitlines():
        if in_repo_config:
            repo_lines.append(line)
            continue
        if line == "---":
            in_repo_config = True
        elif line.startswith("--enablerepo="):
            options.append(("enable", line.split("=", 1)[1]))
        elif line.startswith("--disablerepo="):
            options.append(("disable", line.split("=", 1)[1]))
        elif line.startswith("--repoid="):
            options.append(("repoid", line.split("=", 1)[1]))
        elif line.startswith("--releasever="):
            options.append(("releasever", line.split("=", 1)[1]))
        elif line == "--refresh":
            pass
        elif line:
            spec = line

    return options, spec, "\n".join(repo_lines) + "\n"


def parse_repo_config(repo_text):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.read_string(repo_text)
    return config


def repo_enabled(section, config, options):
    enabled = config.get(section, "enabled", fallback="1").strip().lower()
    is_enabled = enabled not in ("0", "false", "no", "off")
    repoids = []

    for op, pattern in options:
        if op == "repoid":
            repoids.append(pattern)
        elif op in ("enable", "disable") and fnmatch.fnmatchcase(section, pattern):
            is_enabled = op == "enable"

    if repoids and not any(fnmatch.fnmatchcase(section, pat) for pat in repoids):
        is_enabled = False

    return is_enabled


def repo_baseurls(section, config, releasever):
    baseurls = []

    if config.has_option(section, "baseurl"):
        raw = expand_repo_value(config.get(section, "baseurl"), releasever)
        baseurls.extend(item for item in raw.split() if item)

    if not baseurls and config.has_option(section, "metalink"):
        metalink = expand_repo_value(config.get(section, "metalink"), releasever)
        suffix = "/repodata/repomd.xml.metalink"
        if metalink.endswith(suffix):
            baseurls.append(metalink[: -len(suffix)])
        else:
            try:
                root = ET.fromstring(curl_bytes(metalink))
                for element in root.iter():
                    if element.tag.rsplit("}", 1)[-1] != "url" or not element.text:
                        continue
                    url = element.text.strip()
                    marker = "/repodata/repomd.xml"
                    if marker in url:
                        baseurls.append(url.split(marker, 1)[0])
            except (ET.ParseError, subprocess.CalledProcessError):
                pass

    return baseurls


def primary_metadata_url(baseurl):
    repomd_url = urllib.parse.urljoin(baseurl.rstrip("/") + "/",
                                      "repodata/repomd.xml")
    root = ET.fromstring(curl_bytes(repomd_url))
    for data in root.findall(f"{{{REPO_NS}}}data"):
        if data.attrib.get("type") != "primary":
            continue
        location = data.find(f"{{{REPO_NS}}}location")
        if location is None:
            continue
        href = location.attrib.get("href")
        if href:
            return urllib.parse.urljoin(baseurl.rstrip("/") + "/", href)
    raise RuntimeError(f"primary metadata not found in {repomd_url}")


def decompress_metadata(url, data):
    if url.endswith(".zst"):
        return subprocess.check_output(["zstd", "-dc"], input=data)
    if url.endswith(".gz"):
        return gzip.decompress(data)
    return data


def child_text(element, namespace, name, default=""):
    child = element.find(f"{{{namespace}}}{name}")
    if child is None or child.text is None:
        return default
    return child.text


def clean_field(value):
    return " ".join((value or "").replace("|", " ").split())


def parse_packages(repoid, baseurl):
    primary_url = primary_metadata_url(baseurl)
    metadata = decompress_metadata(primary_url, curl_bytes(primary_url))
    root = ET.fromstring(metadata)
    packages = []

    for package in root.findall(f"{{{COMMON_NS}}}package"):
        name = child_text(package, COMMON_NS, "name")
        if not name.startswith(PACKAGE_PREFIX):
            continue

        version = package.find(f"{{{COMMON_NS}}}version")
        size = package.find(f"{{{COMMON_NS}}}size")
        location = package.find(f"{{{COMMON_NS}}}location")
        build_time = package.find(f"{{{COMMON_NS}}}time")
        fmt = package.find(f"{{{COMMON_NS}}}format")
        if version is None or size is None or location is None:
            continue

        license_text = ""
        if fmt is not None:
            license_text = child_text(fmt, RPM_NS, "license", "GPLv3+")

        href = location.attrib.get("href", "")
        packages.append({
            "name": name,
            "epoch": version.attrib.get("epoch", "0") or "0",
            "version": version.attrib.get("ver", ""),
            "release": version.attrib.get("rel", ""),
            "repoid": repoid,
            "size": size.attrib.get("package", "0"),
            "buildtime": (build_time.attrib.get("build", "0")
                          if build_time is not None else "0"),
            "license": license_text or "GPLv3+",
            "url": child_text(package, COMMON_NS, "url",
                              "https://www.qubes-os.org"),
            "summary": child_text(package, COMMON_NS, "summary"),
            "description": child_text(package, COMMON_NS, "description"),
            "download_url": urllib.parse.urljoin(baseurl.rstrip("/") + "/", href),
        })

    return packages


def package_targets(package):
    name = package["name"]
    epoch = package["epoch"]
    version = package["version"]
    release = package["release"]
    targets = [
        f"{name}-{epoch}:{version}-{release}",
        name,
        f"{name}-{epoch}:{version}",
    ]
    if epoch == "0":
        targets.extend([
            f"{name}-{version}-{release}",
            f"{name}-{version}",
        ])
    return targets


def package_matches(package, spec):
    return spec in ("", "*") or any(
        fnmatch.fnmatchcase(target, spec) for target in package_targets(package)
    )


def iter_enabled_packages(config, options):
    releasever = "4.3"
    for op, value in options:
        if op == "releasever":
            releasever = value

    for section in config.sections():
        if not repo_enabled(section, config, options):
            continue
        for baseurl in repo_baseurls(section, config, releasever):
            try:
                yield from parse_packages(section, baseurl)
                break
            except (ET.ParseError, RuntimeError, subprocess.CalledProcessError) as exc:
                print(f"WARNING: failed to query {section} at {baseurl}: {exc}",
                      file=sys.stderr)


def query(config, options, spec):
    for package in iter_enabled_packages(config, options):
        if not package_matches(package, spec):
            continue
        fields = [
            package["name"],
            package["epoch"],
            package["version"],
            package["release"],
            package["repoid"],
            package["size"],
            package["buildtime"],
            package["license"],
            package["url"],
            package["summary"],
            package["description"],
        ]
        print("|".join(clean_field(field) for field in fields) + "|")
    return 0


def download(config, options, spec):
    for package in iter_enabled_packages(config, options):
        if package_matches(package, spec):
            return curl_to_stdout(package["download_url"])
    return error(f"template package not found: {spec}")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("query", "download"):
        return error("usage: qvm-template-repo-query-guix query|download")

    options, spec, repo_text = parse_payload(sys.stdin.read())
    try:
        config = parse_repo_config(repo_text)
    except configparser.Error as exc:
        return error(f"failed to parse template repo config: {exc}")

    if sys.argv[1] == "query":
        return query(config, options, spec)
    return download(config, options, spec)


if __name__ == "__main__":
    raise SystemExit(main())
