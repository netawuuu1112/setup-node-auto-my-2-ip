#!/usr/bin/env python3
import argparse
import asyncio
import getpass
import json
import os
import secrets
import socket
import subprocess
import sys
from pathlib import Path
from uuid import UUID

from remnawave import RemnawaveSDK
from remnawave.models import (
    CreateConfigProfileRequestDto,
    UpdateConfigProfileRequestDto,
    CreateHostInboundData,
    CreateHostRequestDto,
    UpdateHostRequestDto,
    CreateInternalSquadRequestDto,
    UpdateInternalSquadRequestDto,
    ProfileModificationRequestDto,
    ConfigProfileData,
)

VERSION = "2.0.0-test"


def run(*cmd, check=True):
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def docker_running(container: str) -> bool:
    p = run("docker", "ps", "--format", "{{.Names}}", check=False)
    return container in p.stdout.splitlines()


def reality_keys(container: str):
    p = run("docker", "exec", container, "rw-core", "x25519")
    private = public = None
    for line in (p.stdout + p.stderr).splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        k, v = k.strip().lower(), v.strip()
        if "private" in k:
            private = v
        elif "public" in k or "password" in k:
            public = v
    if not private:
        raise RuntimeError("Не удалось получить Reality PrivateKey через rw-core x25519")
    return private, public


def build_profile(args, private_key: str, short_id: str):
    return {
        "log": {"loglevel": "warning"},
        "dns": {"servers": ["1.1.1.1", "8.8.8.8"], "queryStrategy": "UseIPv4"},
        "inbounds": [
            {
                "tag": args.hysteria_tag,
                "port": args.port,
                "listen": "0.0.0.0",
                "protocol": "hysteria",
                "settings": {"users": [], "clients": [], "version": 2},
                "streamSettings": {
                    "network": "hysteria",
                    "security": "tls",
                    "tlsSettings": {
                        "alpn": ["h3"],
                        "certificates": [{
                            "keyFile": args.hysteria_key,
                            "certificateFile": args.hysteria_cert,
                        }],
                    },
                    "hysteriaSettings": {"version": 2},
                },
            },
            {
                "tag": args.reality_tag,
                "port": args.port,
                "listen": "0.0.0.0",
                "protocol": "vless",
                "settings": {"clients": [], "decryption": "none"},
                "sniffing": {
                    "enabled": True,
                    "routeOnly": True,
                    "destOverride": ["http", "tls", "quic"],
                },
                "streamSettings": {
                    "network": "tcp",
                    "sockopt": {"mark": 255, "tcpNoDelay": True, "tcpFastOpen": True},
                    "security": "reality",
                    "tcpSettings": {"header": {"type": "none"}, "acceptProxyProtocol": False},
                    "realitySettings": {
                        "dest": f"{args.reality_target}:443",
                        "show": False,
                        "xver": 0,
                        "spiderX": "",
                        "shortIds": [short_id],
                        "privateKey": private_key,
                        "serverNames": [args.reality_target],
                    },
                },
            },
        ],
        "outbounds": [
            {"tag": "DIRECT", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
            {"tag": "BLOCK", "protocol": "blackhole"},
        ],
        "routing": {
            "rules": [{"type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK"}],
            "domainStrategy": "IPIfNonMatch",
        },
    }


def check_local(args):
    print("\n=== LOCAL CHECKS ===")
    if not docker_running(args.container):
        raise RuntimeError(f"Контейнер {args.container} не запущен")
    print(f"[OK] container: {args.container}")
    for p in (args.hysteria_cert, args.hysteria_key):
        r = run("docker", "exec", args.container, "test", "-f", p, check=False)
        print(("[OK]" if r.returncode == 0 else "[WARN]"), p)
    try:
        ips = sorted({x[4][0] for x in socket.getaddrinfo(args.domain, None, socket.AF_INET)})
        print("[OK] DNS A:", ", ".join(ips))
    except Exception as e:
        print("[WARN] DNS:", e)
    s = socket.socket()
    s.settimeout(5)
    try:
        s.connect((args.reality_target, 443))
        print(f"[OK] Reality target reachable: {args.reality_target}:443")
    except Exception as e:
        print(f"[WARN] Reality target: {e}")
    finally:
        s.close()


def get_sdk(args):
    token = args.panel_token or os.getenv("REMNAWAVE_TOKEN")
    if not token:
        token = getpass.getpass("Remnawave API token: ")
    headers = {}
    api_key = args.panel_api_key or os.getenv("REMNAWAVE_API_KEY")
    if api_key:
        headers["X-Api-Key"] = api_key
    kwargs = {"base_url": args.panel_url.rstrip("/"), "token": token}
    if headers:
        kwargs["custom_headers"] = headers
    return RemnawaveSDK(**kwargs)


async def ensure_profile(sdk, args, config):
    resp = await sdk.config_profiles.get_config_profiles()
    found = next((p for p in resp.config_profiles if p.name == args.profile_name), None)
    if found:
        if not args.update_existing:
            raise RuntimeError(f"Profile '{args.profile_name}' уже существует. Добавь --update-existing")
        print(f"[INFO] updating profile: {found.uuid}")
        out = await sdk.config_profiles.update_config_profile(
            UpdateConfigProfileRequestDto(uuid=found.uuid, name=args.profile_name, config=config)
        )
    else:
        print(f"[INFO] creating profile: {args.profile_name}")
        out = await sdk.config_profiles.create_config_profile(
            CreateConfigProfileRequestDto(name=args.profile_name, config=config)
        )
    return out


async def inbound_map(sdk, profile_uuid):
    rows = await sdk.config_profiles.get_inbounds_by_profile_uuid(str(profile_uuid))
    return {x.tag: x for x in rows}


async def ensure_squad(sdk, args, inbound_uuids):
    resp = await sdk.internal_squads.get_internal_squads()
    found = next((s for s in resp.internal_squads if s.name == args.squad_name), None)
    if found:
        current = {x.uuid for x in found.inbounds}
        merged = sorted(current | set(inbound_uuids), key=str)
        out = await sdk.internal_squads.update_internal_squad(
            UpdateInternalSquadRequestDto(uuid=found.uuid, name=found.name, inbounds=merged)
        )
        print(f"[OK] squad updated: {found.name} ({found.uuid})")
    else:
        out = await sdk.internal_squads.create_internal_squad(
            CreateInternalSquadRequestDto(name=args.squad_name, inbounds=inbound_uuids)
        )
        print(f"[OK] squad created: {args.squad_name} ({out.uuid})")
    return out


async def ensure_host(sdk, args, profile_uuid, inbound_uuid, remark, kind):
    hosts = await sdk.hosts.get_all_hosts()
    found = next((h for h in hosts if h.remark == remark), None)
    inbound = CreateHostInboundData(
        config_profile_uuid=profile_uuid,
        config_profile_inbound_uuid=inbound_uuid,
    )
    nodes = [UUID(args.node_uuid)] if args.node_uuid else []
    common = dict(
        inbound=inbound,
        remark=remark,
        address=args.domain,
        port=args.port,
        nodes=nodes,
        is_disabled=False,
        is_hidden=False,
    )
    if kind == "reality":
        common.update(sni=args.reality_target, fingerprint="chrome")
    else:
        common.update(sni=args.domain)
    if found:
        out = await sdk.hosts.update_host(UpdateHostRequestDto(uuid=found.uuid, **common))
        print(f"[OK] host updated: {remark} ({found.uuid})")
    else:
        out = await sdk.hosts.create_host(CreateHostRequestDto(**common))
        print(f"[OK] host created: {remark} ({out.uuid})")
    return out


async def bind_profile_to_node(sdk, args, profile_uuid, inbound_uuids):
    if not args.node_uuid:
        print("[INFO] --node-uuid не указан: профиль к ноде через API не привязывается")
        return
    body = ProfileModificationRequestDto(
        uuids=[args.node_uuid],
        config_profile=ConfigProfileData(
            activeConfigProfileUuid=str(profile_uuid),
            activeInbounds=[str(x) for x in inbound_uuids],
        ),
    )
    await sdk.nodes.profile_modification(body)
    print(f"[OK] profile/inbounds assigned to node: {args.node_uuid}")


async def panel_apply(args, config, public_key, short_id):
    sdk = get_sdk(args)
    print("\n=== PANEL APPLY ===")
    profile = await ensure_profile(sdk, args, config)
    print(f"[OK] profile: {profile.name} ({profile.uuid})")
    imap = await inbound_map(sdk, profile.uuid)
    missing = [x for x in (args.hysteria_tag, args.reality_tag) if x not in imap]
    if missing:
        raise RuntimeError(f"Панель не вернула inbound после сохранения: {missing}")
    h_id = imap[args.hysteria_tag].uuid
    r_id = imap[args.reality_tag].uuid
    print(f"[OK] Hysteria inbound UUID: {h_id}")
    print(f"[OK] Reality inbound UUID: {r_id}")
    await bind_profile_to_node(sdk, args, profile.uuid, [h_id, r_id])
    squad = await ensure_squad(sdk, args, [h_id, r_id])
    reality_host = await ensure_host(sdk, args, profile.uuid, r_id, args.reality_host_name, "reality")
    hysteria_host = await ensure_host(sdk, args, profile.uuid, h_id, args.hysteria_host_name, "hysteria")
    return {
        "profileUuid": str(profile.uuid),
        "hysteriaInboundUuid": str(h_id),
        "realityInboundUuid": str(r_id),
        "squadUuid": str(squad.uuid),
        "realityHostUuid": str(reality_host.uuid),
        "hysteriaHostUuid": str(hysteria_host.uuid),
        "publicKey": public_key,
        "shortId": short_id,
    }


def doctor(args):
    print("\n=== DOCTOR ===")
    print(run("ss", "-lntup", check=False).stdout)
    p = run("docker", "exec", args.container, "cli", "--dump-config-raw", check=False)
    if p.returncode != 0:
        print("[ERR] effective config dump failed:", p.stderr)
        return 1
    try:
        d = json.loads(p.stdout)
    except Exception as e:
        print("[ERR] effective JSON:", e)
        return 1
    ib = {x.get("tag"): x for x in d.get("inbounds", [])}
    for tag in (args.hysteria_tag, args.reality_tag):
        print("[OK]" if tag in ib else "[ERR]", tag)
    r = ib.get(args.reality_tag, {})
    ss = r.get("streamSettings", {})
    rs = ss.get("realitySettings", {})
    print("Reality network:", ss.get("network"))
    print("Reality security:", ss.get("security"))
    print("Reality flow:", r.get("settings", {}).get("flow"))
    print("Reality dest:", rs.get("dest"))
    expected = (
        ss.get("network") == "tcp"
        and ss.get("security") == "reality"
        and r.get("settings", {}).get("flow") == "xtls-rprx-vision"
        and rs.get("dest") == f"{args.reality_target}:443"
    )
    print("[OK] effective Reality" if expected else "[WARN] effective Reality differs from tested scheme")
    return 0


def parser():
    p = argparse.ArgumentParser(description="Remnawave quick setup v2 with Panel API")
    p.add_argument("command", choices=["apply", "generate", "doctor"])
    p.add_argument("--domain", required=False)
    p.add_argument("--panel-url", default=os.getenv("REMNAWAVE_BASE_URL"))
    p.add_argument("--panel-token", default=None)
    p.add_argument("--panel-api-key", default=None)
    p.add_argument("--container", default="remnanode")
    p.add_argument("--port", type=int, default=443)
    p.add_argument("--profile-name", default="AUTO-H2-REALITY")
    p.add_argument("--squad-name", default="AUTO-H2-REALITY")
    p.add_argument("--hysteria-tag", default="HYSTERIA-BBR")
    p.add_argument("--reality-tag", default="REALITY-TCP")
    p.add_argument("--hysteria-host-name", default="AUTO Hysteria")
    p.add_argument("--reality-host-name", default="AUTO Reality")
    p.add_argument("--hysteria-cert", default="/opt/hysteria/certs/fullchain.pem")
    p.add_argument("--hysteria-key", default="/opt/hysteria/certs/privkey.pem")
    p.add_argument("--reality-target", default="ads.x5.ru")
    p.add_argument("--node-uuid", default=None, help="Если указан, профиль+оба inbound назначаются ноде через API")
    p.add_argument("--update-existing", action="store_true")
    p.add_argument("--output", default="/root/remnawave-profile.json")
    p.add_argument("--state", default="/root/remnawave-panel-auto-state.json")
    return p


def main():
    args = parser().parse_args()
    if args.command == "doctor":
        return doctor(args)
    if not args.domain:
        raise SystemExit("Для generate/apply нужен --domain")
    if args.command == "apply" and not args.panel_url:
        raise SystemExit("Для apply нужен --panel-url или REMNAWAVE_BASE_URL")
    check_local(args)
    private_key, public_key = reality_keys(args.container)
    short_id = secrets.token_hex(8)
    config = build_profile(args, private_key, short_id)
    out = Path(args.output)
    out.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(out, 0o600)
    print(f"[OK] local profile: {out}")
    print(f"[OK] Reality PublicKey: {public_key or '<не распознан>'}")
    print(f"[OK] Reality ShortID: {short_id}")
    state = {
        "version": VERSION,
        "domain": args.domain,
        "profileName": args.profile_name,
        "hysteriaTag": args.hysteria_tag,
        "realityTag": args.reality_tag,
        "realityTarget": args.reality_target,
        "publicKey": public_key,
        "shortId": short_id,
    }
    if args.command == "apply":
        panel_state = asyncio.run(panel_apply(args, config, public_key, short_id))
        state.update(panel_state)
    Path(args.state).write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(args.state, 0o600)
    print(f"[OK] state: {args.state}")
    print("\nReality client/Host expectation:")
    print(f"  Address={args.domain}:{args.port}")
    print(f"  SNI={args.reality_target}")
    print("  Fingerprint=chrome")
    print(f"  PublicKey={public_key}")
    print(f"  ShortID={short_id}")
    print("  Flow=xtls-rprx-vision (Remnawave auto)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        print(f"[FATAL] {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
