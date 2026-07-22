#!/usr/bin/env python3
"""Stream-redact credentials and personal data from logs and evidence."""

import ipaddress
import json
import re
import sys


PRIVATE_KEY_BEGIN = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----")
PRIVATE_KEY_END = re.compile(r"-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----")

# Match a quoted structured value as a unit, then handle unquoted header/logfmt
# values. Authorization is intentionally scheme-agnostic: AWS4, Digest, custom
# schemes, and future formats are just as sensitive as Basic and Bearer.
AUTHORIZATION_QUOTED = re.compile(
    r"(?i)(\bAuthorization\b[\"']?\s*[:=]\s*(?:\[\s*)?)([\"'])"
    r"((?:\\.|(?!\2)[^\r\n])*)\2"
)
AUTHORIZATION_PLAIN = re.compile(
    r"(?i)(\bAuthorization\b[\"']?\s*[:=])"
    r"(?!(?:[^\S\r\n]*[\"']|[^\S\r\n]*\[[^\S\r\n]*[\"']))"
    r"([^\S\r\n]*(?:\[[^\S\r\n]*)?)[^\]\r\n]+"
)
COOKIE_QUOTED = re.compile(
    r"(?i)(\b(?:Set-Cookie|Cookie)\b[\"']?\s*[:=]\s*(?:\[\s*)?)([\"'])"
    r"((?:\\.|(?!\2)[^\r\n])*)\2"
)
COOKIE_PLAIN = re.compile(
    r"(?i)(\b(?:Set-Cookie|Cookie)\b[\"']?\s*[:=])"
    r"(?!(?:[^\S\r\n]*[\"']|[^\S\r\n]*\[[^\S\r\n]*[\"']))"
    r"([^\S\r\n]*(?:\[[^\S\r\n]*)?)[^\]\r\n]+"
)

# Cover both generic and composite identifiers such as
# ELASTIC_APM_SECRET_TOKEN, refresh_token, client_secret, and api-key. Exact
# non-generic kubeconfig/AWS spellings are included as well.
SENSITIVE_NAME = (
    r"(?:[A-Za-z0-9_.-]*(?:token|password|secret|api[_-]?key"
    r"|certificate[_-]?key|encryption[_-]?key|age[_-]?identity"
    r"|kubeconfig|private[_-]?key|access[_-]?key(?:[_-]?id)?"
    r"|signing[_-]?key|tls[_-]?key|credential)[A-Za-z0-9_.-]*"
    r"|AWS_ACCESS_KEY_ID|accessKeyId|client-certificate-data|client-key-data)"
)
SENSITIVE_KEY = re.compile(
    rf"^(?:Authorization|Set-Cookie|Cookie|{SENSITIVE_NAME})$", re.IGNORECASE
)
SENSITIVE_ASSIGNMENT_QUOTED = re.compile(
    rf"(?i)(\b{SENSITIVE_NAME}\b[\"']?\s*[:=]\s*(?:\[\s*)?)([\"'])"
    r"((?:\\.|(?!\2)[^\r\n])*)\2"
)
SENSITIVE_ASSIGNMENT_ARRAY = re.compile(
    rf"(?i)(\b{SENSITIVE_NAME}\b[\"']?\s*[:=]\s*)\[[^\]\r\n]*\]"
)
SENSITIVE_ASSIGNMENT_PLAIN = re.compile(
    rf"(?i)(\b{SENSITIVE_NAME}\b[\"']?\s*[:=])"
    r"(?!(?:[^\S\r\n]*[\"']|[^\S\r\n]*\[[^\S\r\n]*[\"']))"
    r"([^\S\r\n]*(?:\[[^\S\r\n]*)?)[^\r\n]+"
)

PROVIDER_TOKEN = re.compile(
    r"(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})"
)
AGE_IDENTITY = re.compile(r"AGE-SECRET-KEY-[A-Z0-9]+", re.IGNORECASE)
AWS_ACCESS_ID = re.compile(r"(?:AKIA|ASIA)[0-9A-Z]{16}")
EMAIL = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.IGNORECASE)
IPV4 = re.compile(
    r"(?<![0-9])"
    r"(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})"
    r"(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3}"
    r"(?![0-9])"
)
IPV6_CANDIDATE = re.compile(
    r"(?<![0-9A-Za-z:])"
    r"(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}"
    r"(?![0-9A-Za-z:])"
)
STRUCTURED_LINE = re.compile(
    r"^(?P<prefix>(?P<indent>[ \t]*)(?P<sequence>(?:-[ \t]+)+)?"
    r"(?:\"(?P<double>[^\"]+)\"|'(?P<single>[^']+)'"
    r"|(?P<bare>[A-Za-z0-9_.-]+(?:[ \t]+[A-Za-z0-9_.-]+)*))"
    r"[ \t]*:[ \t]*)"
    r"(?P<value>.*?)(?P<newline>\r?\n)?$"
)
ASSIGNMENT_KEY = re.compile(
    r"\b(?P<key>[A-Za-z0-9_.-]+"
    r"(?:[ \t]+[A-Za-z0-9_.-]+){0,4})[ \t]*[:=][ \t]*"
)
YAML_BLOCK_INDICATOR = re.compile(
    r"^[|>](?:(?:[+-][1-9]?)|(?:[1-9][+-]?))?$"
)
YAML_COMPLEX_KEY = re.compile(
    r"^(?P<indent>[ \t]*)(?P<sequence>(?:-[ \t]+)*)"
    r"\?[ \t]+(?:\"(?P<double>[^\"]+)\"|'(?P<single>[^']+)'"
    r"|(?P<bare>[A-Za-z0-9_.-]+(?:[ \t]+[A-Za-z0-9_.-]+)*))"
    r"[ \t]*(?:#.*)?(?:\r?\n)?$"
)
YAML_COMPLEX_VALUE = re.compile(
    r"^(?P<indent>[ \t]*):[ \t]*(?P<value>.*?)(?P<newline>\r?\n)?$"
)
KUBERNETES_SECRET_KIND_LINE = re.compile(
    r"^(?P<indent>[ \t]*)(?:-[ \t]+)?"
    r"(?:\"kind\"|'kind'|kind)[ \t]*:[ \t]*"
    r"(?:\"Secret(?:List)?\"|'Secret(?:List)?'|Secret(?:List)?)"
    r"[ \t]*,?[ \t]*(?:#.*)?(?:\r?\n)?$",
    re.IGNORECASE,
)


def redact_ipv6(match: re.Match[str]) -> str:
    candidate = match.group(0)
    # Bare `::` is frequently a delimiter fragment in scanner output and does
    # not identify a host. All usable IPv6 forms, including ::1, are redacted.
    if candidate == "::":
        return candidate
    try:
        ipaddress.IPv6Address(candidate)
    except ValueError:
        return candidate
    return "[REDACTED_IP]"


def redact_unstructured(line: str) -> str:
    structured = STRUCTURED_LINE.fullmatch(line)
    if structured:
        key = next(
            value
            for value in (
                structured.group("double"),
                structured.group("single"),
                structured.group("bare"),
            )
            if value is not None
        )
        scalar = structured.group("value").strip()
        if (
            is_sensitive_key(key)
            and scalar
            and scalar[0] not in "\"'[{|>"
        ):
            return (
                f'{structured.group("prefix")}"[REDACTED]"'
                f"{structured.group('newline') or ''}"
            )
    assignment = find_sensitive_assignment(line)
    if assignment:
        newline = "\n" if line.endswith(("\n", "\r")) else ""
        return f'{line[:assignment.end()]}[REDACTED]{newline}'
    preserve_quotes = lambda match: (  # noqa: E731 - concise regex callback
        f"{match.group(1)}{match.group(2)}[REDACTED]{match.group(2)}"
    )
    redact_array = lambda match: f'{match.group(1)}["[REDACTED]"]'  # noqa: E731
    line = re.sub(
        r"(?i)(\bAuthorization\b[\"']?\s*[:=]\s*)\[[^\]\r\n]*\]",
        redact_array,
        line,
    )
    line = re.sub(
        r"(?i)(\b(?:Set-Cookie|Cookie)\b[\"']?\s*[:=]\s*)\[[^\]\r\n]*\]",
        redact_array,
        line,
    )
    line = SENSITIVE_ASSIGNMENT_ARRAY.sub(redact_array, line)
    line = AUTHORIZATION_QUOTED.sub(preserve_quotes, line)
    line = AUTHORIZATION_PLAIN.sub(r"\1\2[REDACTED]", line)
    line = COOKIE_QUOTED.sub(preserve_quotes, line)
    line = COOKIE_PLAIN.sub(r"\1\2[REDACTED]", line)
    line = SENSITIVE_ASSIGNMENT_QUOTED.sub(preserve_quotes, line)
    line = SENSITIVE_ASSIGNMENT_PLAIN.sub(r"\1\2[REDACTED]", line)
    line = PROVIDER_TOKEN.sub("[REDACTED_TOKEN]", line)
    line = AGE_IDENTITY.sub("[REDACTED_KEY]", line)
    line = AWS_ACCESS_ID.sub("[REDACTED_KEY]", line)
    line = EMAIL.sub("[REDACTED_EMAIL]", line)
    line = IPV4.sub("[REDACTED_IP]", line)
    return IPV6_CANDIDATE.sub(redact_ipv6, line)


def is_sensitive_key(key: str) -> bool:
    if SENSITIVE_KEY.fullmatch(key):
        return True
    components = [part for part in re.split(r"[._-]+", key.casefold()) if part]
    if components and components[-1] in {"authorization", "cookie"}:
        return True
    compact = re.sub(r"[^a-z0-9]", "", key.casefold())
    return (
        any(
            fragment in compact
            for fragment in (
                "authorization",
                "cookie",
                "token",
                "password",
                "secret",
                "privatekey",
                "encryptionkey",
                "certificatekey",
                "ageidentity",
                "kubeconfig",
                "credential",
                "signingkey",
                "tlskey",
                "clientcertificatedata",
                "clientkeydata",
            )
        )
        or "apikey" in compact
        or "accesskey" in compact
    )


def is_opaque_stream_data_key(key: str) -> bool:
    compact = re.sub(r"[^a-z0-9]", "", key.casefold())
    return compact in {"data", "stringdata", "binarydata"}


def find_sensitive_assignment(line: str) -> re.Match[str] | None:
    for match in ASSIGNMENT_KEY.finditer(line):
        if is_sensitive_key(match.group("key").strip()):
            return match
    return None


def redact_secret_shape(value: object) -> object:
    """Preserve a structured secret's containers while replacing every leaf."""
    if isinstance(value, list):
        return [redact_secret_shape(item) for item in value]
    if isinstance(value, dict):
        return {
            redact_unstructured(str(key)): redact_secret_shape(item)
            for key, item in value.items()
        }
    return "[REDACTED]"


def redact_json_value(value: object) -> object:
    if isinstance(value, dict):
        redacted: dict[str, object] = {}
        for key, item in value.items():
            safe_key = redact_unstructured(str(key))
            redacted[safe_key] = (
                redact_secret_shape(item)
                if is_sensitive_key(str(key))
                else redact_json_value(item)
            )
        return redacted
    if isinstance(value, list):
        return [redact_json_value(item) for item in value]
    if isinstance(value, str):
        if PRIVATE_KEY_BEGIN.search(value):
            return "[REDACTED_PRIVATE_KEY]"
        return redact_unstructured(value)
    return value


def contains_kubernetes_secret(value: object) -> bool:
    if isinstance(value, dict):
        if str(value.get("kind", "")).casefold() in {"secret", "secretlist"}:
            return True
        return any(contains_kubernetes_secret(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_kubernetes_secret(item) for item in value)
    return False


class KubernetesSecretEvidence(ValueError):
    """Raised when an evidence input contains a Kubernetes Secret object."""


def redact_line(line: str, reject_kubernetes_secrets: bool = False) -> str:
    """Redact one log line, preserving valid JSON whenever the whole line is JSON."""
    content = line.rstrip("\r\n")
    newline = line[len(content) :]
    try:
        value = json.loads(content)
    except (json.JSONDecodeError, ValueError):
        return redact_unstructured(line)
    if contains_kubernetes_secret(value):
        if reject_kubernetes_secrets:
            raise KubernetesSecretEvidence
        return '"[REDACTED_KUBERNETES_SECRET]"' + newline
    return json.dumps(
        redact_json_value(value), ensure_ascii=False, separators=(",", ":")
    ) + newline


def redact_stream(lines: object, reject_kubernetes_secrets: bool = False) -> None:
    inside_private_key = False
    sensitive_block_indent: int | None = None
    sensitive_block_from_sequence = False
    pending_complex_secret_indent: int | None = None
    suppressed_secret_document_indent: int | None = None
    for line in lines:
        if suppressed_secret_document_indent is not None:
            stripped = line.lstrip(" \t")
            indent = len(line) - len(stripped)
            if stripped.startswith("---"):
                suppressed_secret_document_indent = None
                sys.stdout.write(line)
                continue
            if (
                indent < suppressed_secret_document_indent
                and stripped.startswith(("}", "]"))
            ):
                suppressed_secret_document_indent = None
                sys.stdout.write(line)
                continue
            continue

        if sensitive_block_indent is not None:
            stripped = line.lstrip(" \t")
            indent = len(line) - len(stripped)
            if not stripped.strip() or stripped.startswith("#"):
                continue
            if indent > sensitive_block_indent:
                continue
            if indent == sensitive_block_indent and stripped.startswith(("]", "}")):
                if stripped.startswith(("]", "}")):
                    sensitive_block_indent = None
                    if stripped[1:].lstrip().startswith(","):
                        sys.stdout.write(",\n")
                continue
            if (
                indent == sensitive_block_indent
                and stripped.startswith("-")
                and not sensitive_block_from_sequence
            ):
                continue
            sensitive_block_indent = None
            sensitive_block_from_sequence = False

        if pending_complex_secret_indent is not None:
            complex_value = YAML_COMPLEX_VALUE.fullmatch(line)
            if complex_value:
                indent = len(complex_value.group("indent"))
                if indent >= pending_complex_secret_indent:
                    value = complex_value.group("value").strip()
                    trailing_comma = "," if value.rstrip().endswith(",") else ""
                    sys.stdout.write(
                        f'{complex_value.group("indent")}: "[REDACTED]"'
                        f'{trailing_comma}{complex_value.group("newline") or ""}'
                    )
                    sensitive_block_indent = pending_complex_secret_indent
                    sensitive_block_from_sequence = False
                    pending_complex_secret_indent = None
                    continue
            pending_complex_secret_indent = None

        if inside_private_key:
            if PRIVATE_KEY_END.search(line):
                inside_private_key = False
            continue
        if PRIVATE_KEY_BEGIN.search(line):
            try:
                json.loads(line)
            except (json.JSONDecodeError, ValueError):
                pass
            else:
                sys.stdout.write(
                    redact_line(line, reject_kubernetes_secrets)
                )
                continue
            sys.stdout.write("[REDACTED_PRIVATE_KEY]\n")
            if not PRIVATE_KEY_END.search(line):
                inside_private_key = True
            continue
        secret_kind = KUBERNETES_SECRET_KIND_LINE.fullmatch(line)
        if secret_kind:
            if reject_kubernetes_secrets:
                raise KubernetesSecretEvidence
            stripped = line.lstrip(" \t")
            if stripped.startswith('"kind"'):
                sys.stdout.write(
                    f'{secret_kind.group("indent")}'
                    '"kind":"Secret",'
                    '"redacted":"[REDACTED_KUBERNETES_SECRET]"\n'
                )
            else:
                sys.stdout.write(
                    f'{secret_kind.group("indent")}'
                    "kind: Secret\n"
                    f'{secret_kind.group("indent")}'
                    "redacted: '[REDACTED_KUBERNETES_SECRET]'\n"
                )
            suppressed_secret_document_indent = len(
                secret_kind.group("indent")
            )
            continue
        structured = STRUCTURED_LINE.fullmatch(line)
        if structured:
            key = next(
                value
                for value in (
                    structured.group("double"),
                    structured.group("single"),
                    structured.group("bare"),
                )
                if value is not None
            )
            value = structured.group("value").strip()
            block_value = value.split("#", 1)[0].rstrip()
            if is_sensitive_key(key) or is_opaque_stream_data_key(key):
                prefix = structured.group("prefix")
                indent = len(structured.group("indent"))
                trailing_comma = (
                    ","
                    if block_value
                    and block_value.rstrip().endswith(",")
                    and not YAML_BLOCK_INDICATOR.fullmatch(block_value)
                    else ""
                )
                sys.stdout.write(
                    f'{prefix}"[REDACTED]"{trailing_comma}'
                    f'{structured.group("newline") or ""}'
                )
                sensitive_block_indent = indent
                sensitive_block_from_sequence = bool(
                    structured.group("sequence")
                )
                continue
        complex_key = YAML_COMPLEX_KEY.fullmatch(line)
        if complex_key:
            key = next(
                value
                for value in (
                    complex_key.group("double"),
                    complex_key.group("single"),
                    complex_key.group("bare"),
                )
                if value is not None
            )
            if is_sensitive_key(key):
                sys.stdout.write(line)
                pending_complex_secret_indent = len(
                    complex_key.group("indent")
                )
                continue
        assignment = find_sensitive_assignment(line)
        if assignment:
            sys.stdout.write(redact_line(line, reject_kubernetes_secrets))
            sensitive_block_indent = len(line) - len(line.lstrip(" \t"))
            sensitive_block_from_sequence = False
            continue
        sys.stdout.write(redact_line(line, reject_kubernetes_secrets))


def main() -> None:
    sys.stdin.reconfigure(errors="replace")
    sys.stdout.reconfigure(errors="replace")
    args = sys.argv[1:]
    if args == ["--document"]:
        content = sys.stdin.read()
        try:
            value = json.loads(content)
        except (json.JSONDecodeError, ValueError):
            try:
                redact_stream(
                    content.splitlines(keepends=True),
                    reject_kubernetes_secrets=True,
                )
            except KubernetesSecretEvidence:
                sys.stderr.write(
                    "[zerops-k8s] ERROR: refusing Kubernetes Secret evidence\n"
                )
                raise SystemExit(3)
            return
        if contains_kubernetes_secret(value):
            sys.stderr.write(
                "[zerops-k8s] ERROR: refusing Kubernetes Secret evidence\n"
            )
            raise SystemExit(3)
        trailing_newline = "\n" if content.endswith(("\n", "\r")) else ""
        sys.stdout.write(
            json.dumps(
                redact_json_value(value),
                ensure_ascii=False,
                separators=(",", ":"),
            )
            + trailing_newline
        )
        return
    if args == ["--yaml-document"]:
        content = sys.stdin.read()
        try:
            import yaml
        except ImportError:
            documents = None
        else:
            try:
                documents = list(yaml.safe_load_all(content))
            except yaml.YAMLError:
                documents = None
        if documents is None:
            sys.stderr.write(
                "[zerops-k8s] ERROR: refusing invalid or unsupported YAML evidence\n"
            )
            raise SystemExit(4)
        if any(contains_kubernetes_secret(document) for document in documents):
            sys.stderr.write(
                "[zerops-k8s] ERROR: refusing Kubernetes Secret evidence\n"
            )
            raise SystemExit(3)
        yaml.safe_dump_all(
            [redact_json_value(document) for document in documents],
            stream=sys.stdout,
            sort_keys=False,
            explicit_start=len(documents) > 1,
        )
        return
    if args:
        sys.stderr.write(
            "usage: redact_stream.py [--document|--yaml-document]\n"
        )
        raise SystemExit(2)
    redact_stream(sys.stdin)


if __name__ == "__main__":
    main()
