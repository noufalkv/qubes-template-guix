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
import io
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import xml.etree.ElementTree as ET
import zlib


REPO_NS = "http://linux.duke.edu/metadata/repo"
COMMON_NS = "http://linux.duke.edu/metadata/common"
RPM_NS = "http://linux.duke.edu/metadata/rpm"
PACKAGE_PREFIX = "qubes-template-"
MAX_PAYLOAD_SIZE = 1024 * 1024
MAX_QUERY_OUTPUT_SIZE = 1024 * 1024
MAX_FIELD_SIZE = 16 * 1024
MAX_OPTION_SIZE = 256
MAX_URL_SIZE = 16 * 1024
MAX_REPOSITORIES = 64
MAX_REPOSITORY_URLS = 16
MAX_REPOSITORY_ATTEMPTS = 16
MAX_DOWNLOAD_ATTEMPTS = 16
MAX_REPOSITORY_PACKAGES = 4096
MAX_METADATA_ELEMENTS = 100_000
MAX_REPOSITORY_INDEX_SIZE = 1024 * 1024
MAX_COMPRESSED_METADATA_SIZE = 32 * 1024 * 1024
MAX_UNCOMPRESSED_METADATA_SIZE = 128 * 1024 * 1024
MAX_METADATA_OPERATION_TIME = 600
MAX_PACKAGE_SIZE = 16 * 1024 * 1024 * 1024
MAX_BUILD_TIMESTAMP = 253402300799  # 9999-12-31T23:59:59Z
MAX_DIAGNOSTIC_SIZE = 512
MAX_DIAGNOSTIC_OUTPUT_SIZE = 1024
ERROR_DIAGNOSTIC_RESERVE = 256
CURL_CONNECT_TIMEOUT = "30"
CURL_LOW_SPEED_LIMIT = "1024"
CURL_LOW_SPEED_TIME = "60"
CURL_METADATA_TIMEOUT = "300"
CURL_DOWNLOAD_TIMEOUT = "7200"
NAME_RE = re.compile(r"\A[A-Za-z0-9._+][A-Za-z0-9._+-]*\Z")
EVR_RE = re.compile(r"\A[A-Za-z0-9._+~]*\Z")
LICENSE_RE = re.compile(r"\A[A-Za-z0-9._+()][A-Za-z0-9._+()-]*\Z")
DIGITS_RE = re.compile(r"\A[0-9]+\Z")
_diagnostic_output_size = 0
_metadata_deadline = None


class PayloadError(ValueError):
    """The qrexec request does not satisfy the expected wire format."""


class RepositoryError(RuntimeError):
    """Repository metadata could not be fetched or safely decoded."""


class DownloadError(RepositoryError):
    """An RPM download failed after TRANSFERRED bytes reached stdout."""

    def __init__(self, message, transferred=0):
        super().__init__(message)
        self.transferred = transferred


def clean_diagnostic(value):
    """Return a short, single-line ASCII diagnostic fragment."""
    bounded = str(value)[:MAX_DIAGNOSTIC_SIZE]
    ascii_value = bounded.encode("ascii", "replace").decode("ascii")
    return " ".join(
        "".join(
            character if " " <= character <= "~" else " "
            for character in ascii_value
        ).split()
    )


def diagnostic(level, message):
    """Write bounded diagnostics without risking a blocked qrexec pipe."""
    global _diagnostic_output_size

    line = f"{level}: {clean_diagnostic(message)}\n"
    output_limit = MAX_DIAGNOSTIC_OUTPUT_SIZE
    if level == "WARNING":
        output_limit -= ERROR_DIAGNOSTIC_RESERVE
    remaining = output_limit - _diagnostic_output_size
    if remaining <= 0:
        return
    line = line[:remaining]
    if not line.endswith("\n"):
        line = line[:-1] + "\n" if len(line) > 1 else ""
    encoded_size = len(line.encode("ascii", "strict"))
    _diagnostic_output_size += encoded_size
    try:
        sys.stderr.write(line)
        sys.stderr.flush()
    except OSError:
        return


def error(message):
    diagnostic("ERROR", message)
    return 1


def warning(message):
    diagnostic("WARNING", message)


def validate_url(url):
    """Return URL when it is an absolute HTTP(S) URL, otherwise fail."""
    if not isinstance(url, str) or len(url) > MAX_URL_SIZE:
        raise RepositoryError("repository URL is missing or too long")
    if any(
            character.isspace() or not character.isprintable()
            for character in url):
        raise RepositoryError("repository URL contains invalid characters")
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = parsed.scheme in ("http", "https") and parsed.hostname
    except ValueError as exc:
        raise RepositoryError("invalid repository URL") from exc
    if not valid:
        raise RepositoryError("unsupported repository URL")
    return url


def join_repository_url(baseurl, reference):
    """Resolve one bounded repository reference to an HTTP(S) URL."""
    if not reference or len(reference) > MAX_URL_SIZE:
        raise RepositoryError("repository URL reference is missing or too long")
    try:
        joined = urllib.parse.urljoin(baseurl.rstrip("/") + "/", reference)
    except ValueError as exc:
        raise RepositoryError("invalid repository URL reference") from exc
    return validate_url(joined)


def command_output_limited(command, limit, *, stdin=None):
    """Run COMMAND and return at most LIMIT bytes of standard output.

    Reading through a pipe, rather than using check_output(), bounds memory
    even when a server sends chunked data without a trustworthy Content-Length.
    """
    process = subprocess.Popen(
        command,
        stdin=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    assert process.stdout is not None
    try:
        output = process.stdout.read(limit + 1)
        if len(output) > limit:
            raise RepositoryError(
                f"command output exceeds {limit} bytes: {command[0]}"
            )
        return_code = process.wait()
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.wait()
        raise
    finally:
        process.stdout.close()

    if return_code:
        raise RepositoryError(
            f"{command[0]} exited with status {return_code}"
        )
    return output


def metadata_timeout():
    """Return a curl timeout within the process-wide metadata deadline."""
    if _metadata_deadline is None:
        return CURL_METADATA_TIMEOUT
    remaining = _metadata_deadline - time.monotonic()
    if remaining <= 0:
        raise RepositoryError("repository metadata query timed out")
    return str(max(1, min(int(CURL_METADATA_TIMEOUT), int(remaining) + 1)))


def curl_bytes(url, limit=MAX_COMPRESSED_METADATA_SIZE):
    """Fetch bounded repository metadata from URL."""
    validate_url(url)
    if not isinstance(limit, int) or not 0 < limit <= MAX_COMPRESSED_METADATA_SIZE:
        raise RepositoryError("invalid repository metadata size limit")
    return command_output_limited(
        ["curl", "--disable", "--globoff",
         "--fail", "--silent", "--show-error", "--location",
         "--proto", "=http,https", "--proto-redir", "=http,https",
         "--connect-timeout", CURL_CONNECT_TIMEOUT,
         "--speed-limit", CURL_LOW_SPEED_LIMIT,
         "--speed-time", CURL_LOW_SPEED_TIME,
         "--max-time", metadata_timeout(),
         "--max-filesize", str(limit), url],
        limit,
    )


def curl_to_stdout(url, expected_size):
    """Stream exactly EXPECTED_SIZE RPM bytes to stdout."""
    if (not isinstance(expected_size, int)
            or not 0 < expected_size <= MAX_PACKAGE_SIZE):
        raise RepositoryError(f"invalid template download size: {expected_size!r}")
    validate_url(url)
    command = ["curl", "--disable", "--globoff",
               "--fail", "--silent", "--show-error", "--location",
               "--proto", "=http,https", "--proto-redir", "=http,https",
               "--connect-timeout", CURL_CONNECT_TIMEOUT,
               "--speed-limit", CURL_LOW_SPEED_LIMIT,
               "--speed-time", CURL_LOW_SPEED_TIME,
               "--max-time", CURL_DOWNLOAD_TIMEOUT,
               "--max-filesize", str(expected_size), "-o", "-", url]
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
    except OSError as exc:
        raise DownloadError("could not start curl") from exc
    assert process.stdout is not None
    output = getattr(sys.stdout, "buffer", sys.stdout)
    transferred = 0
    try:
        while True:
            remaining = expected_size - transferred
            chunk = process.stdout.read(min(1024 * 1024, remaining + 1))
            if not chunk:
                break
            if len(chunk) > remaining:
                raise DownloadError(
                    f"template download exceeds advertised size {expected_size}",
                    transferred,
                )
            output.write(chunk)
            transferred += len(chunk)
        return_code = process.wait()
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.wait()
        raise
    finally:
        process.stdout.close()

    if return_code:
        raise DownloadError(
            f"{command[0]} exited with status {return_code}", transferred
        )
    if transferred != expected_size:
        raise DownloadError(
            "template download size mismatch: "
            f"expected {expected_size}, received {transferred}",
            transferred,
        )
    output.flush()
    return 0


def expand_repo_value(value, releasever):
    replacements = (
        ("${releasever}", releasever),
        ("$releasever", releasever),
        ("${basearch}", "x86_64"),
        ("$basearch", "x86_64"),
    )
    expanded_size = len(value)
    for token, replacement in replacements:
        expanded_size += value.count(token) * (len(replacement) - len(token))
    if expanded_size > MAX_PAYLOAD_SIZE:
        raise RepositoryError("expanded repository configuration is too large")
    for token, replacement in replacements:
        value = value.replace(token, replacement)
    return value


def validated_token(value, label):
    """Return a nonempty printable token with no protocol whitespace."""
    if not value:
        raise PayloadError(f"empty {label}")
    if len(value) > MAX_FIELD_SIZE:
        raise PayloadError(f"{label} exceeds {MAX_FIELD_SIZE} characters")
    if any(
            character.isspace() or not character.isprintable()
            for character in value):
        raise PayloadError(f"invalid character in {label}")
    return value


def option_value(line):
    """Extract and validate the value of a --name=value request option."""
    value = validated_token(line.split("=", 1)[1], "option value")
    if len(value) > MAX_OPTION_SIZE:
        raise PayloadError(
            f"option value exceeds {MAX_OPTION_SIZE} characters"
        )
    return value


def releasever_value(line):
    """Extract a releasever that is safe for repository substitution."""
    value = option_value(line)
    if not EVR_RE.fullmatch(value):
        raise PayloadError("invalid release version")
    return value


def parse_payload(untrusted_stdin_text):
    options = []
    spec = "*"
    repo_lines = []
    in_repo_config = False

    if "\0" in untrusted_stdin_text:
        raise PayloadError("NUL byte in request")

    spec_seen = False
    for line in untrusted_stdin_text.split("\n"):
        if in_repo_config:
            repo_lines.append(line)
            continue
        if line == "---":
            in_repo_config = True
        elif line.startswith("--enablerepo="):
            options.append(("enable", option_value(line)))
        elif line.startswith("--disablerepo="):
            options.append(("disable", option_value(line)))
        elif line.startswith("--repoid="):
            options.append(("repoid", option_value(line)))
        elif line.startswith("--releasever="):
            options.append(("releasever", releasever_value(line)))
        elif line == "--refresh":
            pass
        elif line.startswith("--"):
            raise PayloadError(f"unsupported option: {line}")
        elif line:
            if spec_seen:
                raise PayloadError("multiple package specifications")
            spec = validated_token(line, "package specification")
            spec_seen = True

    if not in_repo_config:
        raise PayloadError("missing repository-config delimiter")

    return options, spec, "\n".join(repo_lines)


def read_payload(stream):
    """Read and strictly decode a byte-bounded qrexec request from STREAM."""
    payload = stream.read(MAX_PAYLOAD_SIZE + 1)
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    if len(payload) > MAX_PAYLOAD_SIZE:
        raise PayloadError(
            f"request exceeds {MAX_PAYLOAD_SIZE} bytes"
        )
    try:
        return payload.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        raise PayloadError("request is not valid UTF-8") from exc


def parse_repo_config(repo_text):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.read_string(repo_text)
    if not config.sections():
        raise PayloadError("repository config has no sections")
    if len(config.sections()) > MAX_REPOSITORIES:
        raise PayloadError(
            f"repository config exceeds {MAX_REPOSITORIES} sections"
        )
    return config


def repo_enabled(section, config, options):
    repoids = [
        pattern for operation, pattern in options
        if operation == "repoid"
    ]
    if repoids:
        # qvm-template defines --repoid as "enable just specific
        # repositories".  It therefore overrides both each repository's
        # configured state and any --enablerepo/--disablerepo options.
        return any(
            fnmatch.fnmatchcase(section, pattern) for pattern in repoids
        )

    enabled = config.get(section, "enabled", fallback="1").strip().lower()
    is_enabled = enabled not in ("0", "false", "no", "off")

    for op, pattern in options:
        if (op in ("enable", "disable")
                and fnmatch.fnmatchcase(section, pattern)):
            is_enabled = op == "enable"

    return is_enabled


def repo_baseurls(section, config, releasever):
    baseurls = []

    def append_baseurl(url, *, limit, reject_excess):
        if url in baseurls:
            return True
        if len(baseurls) >= limit:
            if reject_excess:
                raise RepositoryError("repository has too many base URLs")
            return False
        baseurls.append(url)
        return True

    if config.has_option(section, "baseurl"):
        raw = expand_repo_value(config.get(section, "baseurl"), releasever)
        for item in raw.split():
            append_baseurl(
                item,
                limit=MAX_REPOSITORY_URLS,
                reject_excess=True,
            )

    if not baseurls and config.has_option(section, "metalink"):
        metalink = expand_repo_value(config.get(section, "metalink"),
                                     releasever)
        suffix = "/repodata/repomd.xml.metalink"
        fallback_baseurl = None
        if metalink.endswith(suffix):
            fallback_baseurl = validate_url(metalink[: -len(suffix)])

        try:
            root = parse_xml_root(
                curl_bytes(metalink, MAX_REPOSITORY_INDEX_SIZE),
                "repository metalink",
            )
        except RepositoryError:
            if fallback_baseurl is None:
                raise
            # The canonical Qubes metalink URL also identifies a usable origin.
            # Retain that origin when mirror discovery is temporarily
            # unavailable or malformed.
            return [fallback_baseurl]

        mirror_limit = min(
            MAX_REPOSITORY_URLS, MAX_REPOSITORY_ATTEMPTS
        )
        for element in root.iter():
            if (element.tag.rsplit("}", 1)[-1] != "url"
                    or not element.text
                    or len(element.text) > MAX_URL_SIZE):
                continue
            url = element.text.strip()
            marker = "/repodata/repomd.xml"
            if marker in url:
                candidate = url.split(marker, 1)[0]
                try:
                    validate_url(candidate)
                except RepositoryError:
                    continue
                if not append_baseurl(
                        candidate,
                        limit=mirror_limit,
                        reject_excess=False):
                    break

        if fallback_baseurl is not None and fallback_baseurl not in baseurls:
            if len(baseurls) < mirror_limit:
                baseurls.append(fallback_baseurl)
            elif baseurls:
                # Reserve one bounded attempt for the origin encoded by the
                # metalink URL itself.
                baseurls[-1] = fallback_baseurl

    return baseurls


def package_download_urls(package, baseurls):
    """Return bounded mirror URLs for one package metadata record."""
    urls = [package["download_url"]]
    reference = package.get("download_reference")
    if reference:
        for baseurl in baseurls:
            try:
                candidate = join_repository_url(baseurl, reference)
            except RepositoryError:
                continue
            if candidate not in urls:
                urls.append(candidate)
            if len(urls) >= MAX_REPOSITORY_URLS:
                break
    return tuple(urls)


def primary_metadata_url(baseurl):
    validate_url(baseurl)
    repomd_url = urllib.parse.urljoin(baseurl.rstrip("/") + "/",
                                      "repodata/repomd.xml")
    root = parse_xml_root(
        curl_bytes(repomd_url, MAX_REPOSITORY_INDEX_SIZE),
        "repository index",
    )
    for data in root.findall(f"{{{REPO_NS}}}data"):
        if data.attrib.get("type") != "primary":
            continue
        location = data.find(f"{{{REPO_NS}}}location")
        if location is None:
            continue
        href = location.attrib.get("href")
        if href:
            return join_repository_url(baseurl, href)
    raise RepositoryError("primary repository metadata is missing")


def decompress_metadata(url, data):
    validate_url(url)
    metadata_path = urllib.parse.urlsplit(url).path
    if metadata_path.endswith(".zst"):
        with tempfile.TemporaryFile() as compressed:
            compressed.write(data)
            compressed.seek(0)
            return command_output_limited(
                ["zstd", "-dc"], MAX_UNCOMPRESSED_METADATA_SIZE,
                stdin=compressed,
            )
    if metadata_path.endswith(".gz"):
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
                metadata = compressed.read(MAX_UNCOMPRESSED_METADATA_SIZE + 1)
        except (EOFError, OSError, zlib.error) as exc:
            raise RepositoryError("invalid gzip repository metadata") from exc
    else:
        metadata = data

    if len(metadata) > MAX_UNCOMPRESSED_METADATA_SIZE:
        raise RepositoryError(
            "uncompressed repository metadata exceeds "
            f"{MAX_UNCOMPRESSED_METADATA_SIZE} bytes"
        )
    return metadata


def child_text(element, namespace, name, default=""):
    child = element.find(f"{{{namespace}}}{name}")
    if child is None or child.text is None:
        return default
    return child.text


def parse_xml_root(data, label):
    """Parse a small XML document and normalize decoder/parser failures."""
    try:
        return ET.fromstring(data)
    except (ET.ParseError, LookupError) as exc:
        raise RepositoryError(f"invalid {label} XML") from exc


def iter_package_elements(metadata):
    """Yield package elements while releasing processed root children."""
    stack = []
    element_count = 0
    package_tag = f"{{{COMMON_NS}}}package"
    try:
        events = ET.iterparse(io.BytesIO(metadata), events=("start", "end"))
        for event, element in events:
            if event == "start":
                stack.append(element)
                element_count += 1
                if element_count > MAX_METADATA_ELEMENTS:
                    raise RepositoryError(
                        "repository metadata contains too many XML elements"
                    )
                continue

            depth = len(stack)
            direct_package = depth == 2 and element.tag == package_tag
            if direct_package:
                yield element

            parent = stack[-2] if depth > 1 else None
            inside_direct_package = depth > 2 and stack[1].tag == package_tag
            if parent is not None and (depth == 2 or not inside_direct_package):
                # Element.clear() alone leaves an empty child referenced by its
                # parent.  Remove processed nodes outside a package, and remove
                # the complete package after the caller extracts its fields.
                parent.remove(element)
            stack.pop()
    except (ET.ParseError, LookupError) as exc:
        raise RepositoryError("invalid primary repository metadata XML") from exc


def clean_field(value):
    """Return one printable ASCII qrexec field with no row delimiters."""
    bounded = (value or "")[:MAX_FIELD_SIZE]
    ascii_value = bounded.encode("ascii", "replace").decode("ascii")
    printable = "".join(
        character if " " <= character <= "~" else " "
        for character in ascii_value
    )
    normalized = " ".join(printable.replace("|", " ").split())
    return normalized[:MAX_FIELD_SIZE]


def valid_package_fields(package):
    """Return whether PACKAGE matches qvm-template's strict row grammar."""
    structural_fields = (
        "name", "epoch", "version", "release", "repoid", "size",
        "buildtime", "license",
    )
    if any(
            len(package[field]) > MAX_FIELD_SIZE
            for field in structural_fields):
        return False
    name = package["name"]
    template_name = name[len(PACKAGE_PREFIX):]
    if not NAME_RE.fullmatch(template_name):
        return False
    if not all(
            EVR_RE.fullmatch(package[field])
            for field in ("epoch", "version", "release")):
        return False
    if not NAME_RE.fullmatch(package["repoid"]):
        return False
    if (len(package["size"]) > 20
            or not DIGITS_RE.fullmatch(package["size"])):
        return False
    size = int(package["size"])
    if not 0 < size <= MAX_PACKAGE_SIZE:
        return False
    if (len(package["buildtime"]) > 20
            or not DIGITS_RE.fullmatch(package["buildtime"])):
        return False
    if int(package["buildtime"]) > MAX_BUILD_TIMESTAMP:
        return False
    if not LICENSE_RE.fullmatch(package["license"]):
        return False
    return True


def parse_packages(repoid, baseurl):
    primary_url = primary_metadata_url(baseurl)
    metadata = decompress_metadata(primary_url, curl_bytes(primary_url))

    # Validate the complete document and cap its relevant record count before
    # yielding anything.  This preserves all-or-nothing base-URL fallback while
    # avoiding a list of every template package in memory.
    package_count = 0
    for package in iter_package_elements(metadata):
        package_count += 1
        if package_count > MAX_REPOSITORY_PACKAGES:
            raise RepositoryError(
                "repository contains too many package records"
            )
        package.clear()

    # Clear each package after extracting bounded fields so a large primary.xml
    # does not create a second, comparably-sized ElementTree or candidate list.
    for package in iter_package_elements(metadata):
        name = child_text(package, COMMON_NS, "name")
        if not name.startswith(PACKAGE_PREFIX):
            package.clear()
            continue

        version = package.find(f"{{{COMMON_NS}}}version")
        size = package.find(f"{{{COMMON_NS}}}size")
        location = package.find(f"{{{COMMON_NS}}}location")
        build_time = package.find(f"{{{COMMON_NS}}}time")
        fmt = package.find(f"{{{COMMON_NS}}}format")
        if version is None or size is None or location is None:
            package.clear()
            continue

        license_text = ""
        if fmt is not None:
            license_text = child_text(fmt, RPM_NS, "license", "GPLv3+")

        href = location.attrib.get("href", "")
        try:
            download_url = join_repository_url(baseurl, href)
        except RepositoryError:
            package.clear()
            continue
        candidate = {
            "name": name,
            "epoch": version.attrib.get("epoch", "0") or "0",
            "version": version.attrib.get("ver", ""),
            "release": version.attrib.get("rel", ""),
            "repoid": repoid,
            "size": size.attrib.get("package", "0"),
            "buildtime": (build_time.attrib.get("build", "0")
                          if build_time is not None else "0"),
            "license": license_text or "GPLv3+",
            "url": clean_field(child_text(
                package, COMMON_NS, "url", "https://www.qubes-os.org"
            )),
            "summary": clean_field(child_text(
                package, COMMON_NS, "summary"
            )),
            "description": clean_field(child_text(
                package, COMMON_NS, "description"
            )),
            "download_url": download_url,
            "download_reference": href,
        }
        package.clear()
        if valid_package_fields(candidate):
            yield candidate


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
    attempts = 0
    enabled_repositories = 0
    successful_repositories = 0
    for op, value in options:
        if op == "releasever":
            releasever = value

    for section in config.sections():
        if not repo_enabled(section, config, options):
            continue
        enabled_repositories += 1
        try:
            baseurls = repo_baseurls(section, config, releasever)
        except (OSError, RepositoryError) as exc:
            warning(
                f"failed to resolve repository {section}: {exc}"
            )
            continue
        if not baseurls:
            warning(
                f"failed to resolve repository {section}: "
                "no supported repository URL"
            )
            continue
        for baseurl in baseurls:
            attempts += 1
            if attempts > MAX_REPOSITORY_ATTEMPTS:
                warning("repository URL attempt limit reached")
                raise RepositoryError(
                    "repository URL attempt limit reached before all enabled "
                    "repositories were queried"
                )
            try:
                for package in parse_packages(section, baseurl):
                    package["download_urls"] = package_download_urls(
                        package, baseurls
                    )
                    yield package
                successful_repositories += 1
                break
            except (OSError, RepositoryError) as exc:
                warning(
                    f"failed to query repository {section}: {exc}"
                )

    if enabled_repositories and not successful_repositories:
        raise RepositoryError("all enabled repositories failed")


def query(config, options, spec):
    output = getattr(sys.stdout, "buffer", sys.stdout)
    output_size = 0
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
        row = "|".join(clean_field(field) for field in fields) + "|\n"
        encoded_row = row.encode("ascii", "strict")
        output_size += len(encoded_row)
        if output_size > MAX_QUERY_OUTPUT_SIZE:
            return error(
                f"query output exceeds {MAX_QUERY_OUTPUT_SIZE} bytes"
            )
        if hasattr(output, "write") and output is not sys.stdout:
            output.write(encoded_row)
        else:
            output.write(row)
    output.flush()
    return 0


def download(config, options, spec):
    matched = False
    last_error = None
    attempts = 0
    for package in iter_enabled_packages(config, options):
        if not package_matches(package, spec):
            continue
        matched = True
        urls = package.get("download_urls", (package["download_url"],))
        for url in urls:
            if attempts >= MAX_DOWNLOAD_ATTEMPTS:
                return error(
                    "template download attempt limit reached: "
                    f"{MAX_DOWNLOAD_ATTEMPTS}"
                )
            attempts += 1
            try:
                return curl_to_stdout(
                    url, int(package["size"])
                )
            except RepositoryError as exc:
                last_error = exc
                if isinstance(exc, DownloadError) and exc.transferred:
                    # Bytes already reached dom0; another URL would concatenate
                    # streams and corrupt the RPM.
                    return error(f"template download failed: {exc}")
                warning(f"template download attempt failed: {exc}")
    if matched:
        if last_error is None:
            return error("template download failed: no repository URLs")
        return error(f"template download failed: {last_error}")
    return error(f"template package not found: {spec}")


def main():
    global _diagnostic_output_size, _metadata_deadline

    _diagnostic_output_size = 0
    _metadata_deadline = time.monotonic() + MAX_METADATA_OPERATION_TIME
    if len(sys.argv) != 2 or sys.argv[1] not in ("query", "download"):
        return error("usage: qvm-template-repo-query-guix query|download")

    try:
        # Treat qrexec input as untrusted until its size and shape are checked.
        untrusted_stdin_text = read_payload(
            getattr(sys.stdin, "buffer", sys.stdin)
        )
        options, spec, repo_text = parse_payload(untrusted_stdin_text)
        config = parse_repo_config(repo_text)
    except (configparser.Error, PayloadError) as exc:
        return error(f"invalid template repository request: {exc}")

    try:
        if sys.argv[1] == "query":
            return query(config, options, spec)
        return download(config, options, spec)
    except (OSError, RepositoryError) as exc:
        return error(f"template repository operation failed: {exc}")


if __name__ == "__main__":
    raise SystemExit(main())
