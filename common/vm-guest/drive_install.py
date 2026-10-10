#!/usr/bin/env python3
"""
common/vm-guest/drive_install.py — a clean freedomnas-installer run with
every dialog answered from seed.env, for building a disk image.

A title this script does not know stops the build instead of guessing: an
installer that grew a new question needs an answer decided here.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("FNAS_INSTALL_ROOT", "/usr/lib/freedomnas"), "installer", "lib"))

from context import ExecutionContext
from installer_modules import Configuration, DialogManager
from target_installer import CleanInstaller

EDITION = os.environ["FNAS_EDITION"]
DISK = os.environ["FNAS_DISK"]
INIT = os.environ.get("FNAS_INIT", "")
HOSTNAME = os.environ.get("FNAS_HOSTNAME", "freedomnas")
ADMIN_USER = os.environ["FNAS_ADMIN_USER"]
ADMIN_PASSWORD = os.environ["FNAS_ADMIN_PASSWORD"]
TARGET_ROOT = os.environ.get("FNAS_TARGET_ROOT", "/mnt/fnas")


class Unanswered(RuntimeError):
    pass


def _tags(items):
    return [item[0] for item in items]


class ScriptedDialog(DialogManager):
    @classmethod
    def menu(cls, title, text, items, *args, **kwargs):
        tags = _tags(items)
        print(f"[menu] {title}: {tags}", flush=True)
        if title == "Select Installation Disk":
            return next(t for t in tags if t == DISK)
        if title == "Init System":
            if INIT and INIT not in tags:
                raise Unanswered(f"init system {INIT!r} not offered: {tags}")
            return INIT or tags[0]
        if title == "Bootstrap Method":
            return next(t for t in tags if t != "tarball")
        if title == "Package Mirror":
            return tags[0]
        if title == "Timezone — Region":
            return "UTC"
        raise Unanswered(f"menu {title!r}")

    @classmethod
    def checklist(cls, title, text, items, *args, **kwargs):
        chosen = [tag for tag, _, on in items if on]
        print(f"[checklist] {title}: {chosen}", flush=True)
        if title == "Optional Features":
            return chosen
        raise Unanswered(f"checklist {title!r}")

    @classmethod
    def inputbox(cls, title, text, init_text="", *args, **kwargs):
        answers = {
            "Root Pool Name": "rpool",
            "System Hostname": HOSTNAME,
            "Administrator Account": ADMIN_USER,
        }
        if os.environ.get("FNAS_ROOTFS_URL"):
            answers["Rootfs Tarball"] = os.environ["FNAS_ROOTFS_URL"]
        elif init_text:
            answers["Rootfs Tarball"] = init_text
        if title not in answers:
            raise Unanswered(f"inputbox {title!r}")
        print(f"[input] {title}: {answers[title]}", flush=True)
        return answers[title]

    @classmethod
    def passwordbox(cls, title, text, *args, **kwargs):
        if title in ("Password", "Confirm Password"):
            return ADMIN_PASSWORD
        raise Unanswered(f"passwordbox {title!r}")

    @classmethod
    def yesno(cls, title, text, *args, **kwargs):
        answers = {"Confirm Timezone": True, "Additional Users": False}
        if title not in answers:
            raise Unanswered(f"yesno {title!r}")
        print(f"[yesno] {title}: {answers[title]}", flush=True)
        return answers[title]

    @classmethod
    def defaultno(cls, title, text, *args, **kwargs):
        if title != "Confirm Installation":
            raise Unanswered(f"defaultno {title!r}")
        print(f"[defaultno] {title}: True", flush=True)
        return True

    @classmethod
    def msgbox(cls, title, text, *args, **kwargs):
        print(f"[msgbox] {title}:\n{text}", flush=True)


config = Configuration()
config.image_mode = True
config.target_os = EDITION
config.target_root = TARGET_ROOT
os.makedirs(TARGET_ROOT, exist_ok=True)
ctx = ExecutionContext(target_os=EDITION, target_root=TARGET_ROOT, dry_run=False)
installer = CleanInstaller(ScriptedDialog, config, ctx)
try:
    ok = installer.run()
except Exception as exc:
    print(f"install failed: {exc}", flush=True)
    if hasattr(installer, "cleanup"):
        installer.cleanup()
    sys.exit(1)
if ok and getattr(installer.zfs, "export_failed", False):
    print(f"pool {config.pool_name} is still imported", flush=True)
    ok = False
sys.exit(0 if ok else 1)
