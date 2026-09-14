#!/usr/bin/env python3
import argparse
import asyncio
import getpass
import json
import os
import subprocess
import sys
from pathlib import Path

from remnawave import RemnawaveSDK
from safe_guard import make_backup

VERSION = "2.1.0-safe"


def dump_obj(obj):
    if hasattr(obj, "model_dump"):
        return obj.model_dump(mode="json", by_alias=True)
    if isinstance(obj, list):
        return [dump_obj(x) for x in obj]
    if isinstance(obj, dict):
        return {k: dump_obj(v) for k, v in obj.items()}
    return str(obj)


def sdk_for(args):
    token = os.getenv("REMNAWAVE_TOKEN") or getpass.getpass("Remnawave API token: ")
    return RemnawaveSDK(base_url=args.panel_url.rstrip("/"), token=token)


async def discover(sdk):
    profiles = await sdk.config_profiles.get_config_profiles()
    hosts = await sdk.hosts.get_all_hosts()
    squads = await sdk.internal_squads.get_internal_squads()
    nodes = await sdk.nodes.get_all_nodes()
    return profiles, hosts, squads, nodes


def collision_check(args, profiles, hosts, squads):
    collisions = []
    if any(x.name == args.profile_name for x in profiles.config_profiles):
        collisions.append(f"profile:{args.profile_name}")
    if any(x.name == args.squad_name for x in squads.internal_squads):
        collisions.append(f"squad:{args.squad_name}")
    if any(x.remark == args.reality_host_name for x in hosts):
        collisions.append(f"host:{args.reality_host_name}")
    if any(x.remark == args.hysteria_host_name for x in hosts):
        collisions.append(f"host:{args.hysteria_host_name}")
    if collisions:
        raise RuntimeError(
            "Найдены существующие объекты: " + ", ".join(collisions) +
            ". SAFE v2.1 никогда их не обновляет и останавливается."
        )


def show_plan(args):
    print("\n=== SAFE PLAN ===")
    print("Mode: CREATE-ONLY")
    print("Delete operations: DISABLED")
    print("Update existing objects: DISABLED")
    print("Node profile reassignment: DISABLED")
    print("Host node-binding changes: DISABLED")
    print("Will create profile:", args.profile_name)
    print("Will create squad:", args.squad_name)
    print("Will create host:", args.hysteria_host_name)
    print("Will create host:", args.reality_host_name)
    print("Domain:", args.domain)
    print("Reality target:", args.reality_target)


def call_legacy(args):
    here = Path(__file__).resolve().parent
    legacy = here / "setup-node-panel.py"
    cmd = [
        sys.executable, str(legacy), "apply",
        "--domain", args.domain,
        "--panel-url", args.panel_url,
        "--profile-name", args.profile_name,
        "--squad-name", args.squad_name,
        "--hysteria-tag", args.hysteria_tag,
        "--reality-tag", args.reality_tag,
        "--hysteria-host-name", args.hysteria_host_name,
        "--reality-host-name", args.reality_host_name,
        "--reality-target", args.reality_target,
        "--container", args.container,
        "--hysteria-cert", args.hysteria_cert,
        "--hysteria-key", args.hysteria_key,
    ]
    env = os.environ.copy()
    result = subprocess.run(cmd, env=env)
    return result.returncode


async def main_async(args):
    if args.node_uuid:
        raise RuntimeError(
            "SAFE v2.1 не принимает --node-uuid: автоматическое переключение рабочей ноды заблокировано. "
            "Сначала протестируй создание объектов без привязки."
        )

    sdk = sdk_for(args)
    profiles, hosts, squads, nodes = await discover(sdk)
    collision_check(args, profiles, hosts, squads)
    show_plan(args)

    if not args.execute:
        print("\n[SAFE] PLAN завершён. Панель НЕ изменялась.")
        print("Для создания новых TEST-объектов добавь --execute")
        return 0

    backup = make_backup(args.backup_dir, {
        "profiles.json": dump_obj(profiles),
        "hosts.json": dump_obj(list(hosts)),
        "internal-squads.json": dump_obj(squads),
        "nodes.json": dump_obj(list(nodes)),
    })
    print("[OK] snapshot:", backup)
    print("[INFO] Запускается create-only операция. Существующие совпадающие имена уже заблокированы.")

    rc = call_legacy(args)
    if rc != 0:
        print("[ERR] Создание завершилось ошибкой. Snapshot сохранён:", backup)
        print("[SAFE] Автоматического удаления/rollback нет.")
        return rc

    print("[OK] Новые TEST-объекты созданы.")
    print("[SAFE] Рабочая нода автоматически НЕ переключалась.")
    print("[SAFE] Существующие объекты не обновлялись и не удалялись.")
    return 0


def parser():
    p = argparse.ArgumentParser(description="Remnawave Panel SAFE v2.1 create-only wrapper")
    p.add_argument("--domain", required=True)
    p.add_argument("--panel-url", default=os.getenv("REMNAWAVE_BASE_URL"), required=False)
    p.add_argument("--container", default="remnanode")
    p.add_argument("--profile-name", default="TEST-AUTO-H2-REALITY")
    p.add_argument("--squad-name", default="TEST-AUTO-H2-REALITY")
    p.add_argument("--hysteria-tag", default="HYSTERIA-BBR-TEST")
    p.add_argument("--reality-tag", default="REALITY-TCP-TEST")
    p.add_argument("--hysteria-host-name", default="TEST AUTO Hysteria")
    p.add_argument("--reality-host-name", default="TEST AUTO Reality")
    p.add_argument("--reality-target", default="ads.x5.ru")
    p.add_argument("--hysteria-cert", default="/opt/hysteria/certs/fullchain.pem")
    p.add_argument("--hysteria-key", default="/opt/hysteria/certs/privkey.pem")
    p.add_argument("--backup-dir", default="/root/remnawave-panel-auto-backups")
    p.add_argument("--node-uuid", default=None)
    p.add_argument("--execute", action="store_true")
    return p


def main():
    args = parser().parse_args()
    if not args.panel_url:
        raise SystemExit("Нужен --panel-url или REMNAWAVE_BASE_URL")
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print("[STOP]", e, file=sys.stderr)
        raise SystemExit(1)
