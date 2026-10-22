#!/usr/bin/env python3

import contextlib
import errno
import importlib.util
import io
import os
import pathlib
import tempfile
import unittest
from unittest import mock
import uuid

FILES = pathlib.Path(__file__).resolve().parents[1] / "roles/pve-ct-system-uuid/files"

def load(name):
    spec = importlib.util.spec_from_file_location(name, FILES / ("%s.py" % name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

patch = load("patch_smbios_uuid")
conf = load("ct_conf_entries")
registry = load("ct_uuid_registry")

ASYM = "01234567-89ab-cdef-0123-456789abcdef"
ASYM_BYTES_LE = bytes.fromhex("67452301ab89efcd0123456789abcdef")

def structure(stype, formatted, strings=()):

    body = bytes([stype, len(formatted) + 4, 0x00, 0x00]) + formatted
    payload = b""
    for text in strings:
        payload += text + b"\x00"
    return body + payload + b"\x00"

def system_info(formatted_extra=b"", system_uuid=ASYM, strings=(b"Maker", b"Product")):

    formatted = b"\x00\x00\x00\x00" + uuid.UUID(system_uuid).bytes_le
    formatted += b"\x00\x00\x00" + formatted_extra
    return structure(1, formatted, strings)

def dmi_table(type1=None):
    bios = structure(0, b"\x01\x02" + b"\x00" * 20, (b"Vendor", b"Version"))
    processor = structure(4, b"\x03" * 40)
    end = structure(127, b"")
    return bios + (type1 if type1 is not None else system_info()) + processor + end

class PatchSmbiosUuidTest(unittest.TestCase):
    def test_only_the_uuid_bytes_change(self):
        source = dmi_table()
        target = uuid.UUID("45c26f8b-97a4-5079-a5f5-a4f544f0f963")
        patched = patch.patch_table(source, target)

        self.assertEqual(len(patched), len(source))
        offset = patch.find_system_information(source) + patch.SYSTEM_UUID_OFFSET
        self.assertEqual(patched[:offset], source[:offset])
        self.assertEqual(patched[offset + 16:], source[offset + 16:])
        self.assertEqual(patched[offset:offset + 16], target.bytes_le)
        self.assertEqual(patch.read_system_uuid(patched), str(target))
        self.assertEqual(patch.read_system_uuid(source), ASYM)

    def test_uuid_byte_order_is_smbios(self):
        patched = patch.patch_table(dmi_table(), uuid.UUID(ASYM))
        offset = patch.find_system_information(patched) + patch.SYSTEM_UUID_OFFSET
        self.assertEqual(patched[offset:offset + 16], ASYM_BYTES_LE)
        self.assertEqual(patched[offset:offset + 16], uuid.UUID(ASYM).bytes_le)

    def test_roundtrip_through_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = os.path.join(tmp, "DMI.source")
            patched = patch.patch_table(dmi_table(), uuid.UUID(ASYM))
            with open(source, "wb") as handle:
                handle.write(patched)
            with open(source, "rb") as handle:
                self.assertEqual(patch.read_system_uuid(handle.read()), ASYM)

    def test_missing_type1_fails_loudly(self):
        table_without_type1 = structure(0, b"\x00" * 20) + structure(127, b"")
        with self.assertRaises(patch.PatchError):
            patch.patch_table(table_without_type1, uuid.UUID(ASYM))

    def test_short_type1_fails_loudly(self):
        short = structure(1, b"\x00" * 8)
        with self.assertRaises(patch.PatchError):
            patch.patch_table(dmi_table(short), uuid.UUID(ASYM))

    def test_reserved_and_malformed_uuids_are_rejected(self):
        for value in ("00000000-0000-0000-0000-000000000000",
                      "ffffffff-ffff-ffff-ffff-ffffffffffff",
                      "not-a-uuid",
                      ""):
            with self.assertRaises(patch.PatchError):
                patch.parse_uuid(value)

    def test_parse_accepts_uppercase_and_normalises(self):
        self.assertEqual(patch.parse_uuid(ASYM.upper()), uuid.UUID(ASYM))

    def test_uuid_name_uses_uuid5(self):
        expected = uuid.uuid5(uuid.NAMESPACE_DNS, "pve-ct-host:1201")
        self.assertEqual(patch.uuid_from_name("pve-ct-host:1201"), expected)
        self.assertEqual(patch.uuid_from_name("pve-ct-host:1202") != expected, True)
        with self.assertRaises(patch.PatchError):
            patch.uuid_from_name("  ")

    def test_cli_writes_files_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = os.path.join(tmp, "DMI")
            with open(source, "wb") as handle:
                handle.write(dmi_table())
            dest = os.path.join(tmp, "dmi", "1201")
            argv = ["--source", source, "--dest-dir", dest, "--uuid-name", "pve-ct-host:1201"]

            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(patch.main(argv), 0)
            expected = str(uuid.uuid5(uuid.NAMESPACE_DNS, "pve-ct-host:1201"))
            self.assertEqual(out.getvalue().strip(), "uuid=%s changed" % expected)

            with open(os.path.join(dest, "product_uuid")) as handle:
                self.assertEqual(handle.read(), expected + "\n")
            with open(os.path.join(dest, "DMI"), "rb") as handle:
                self.assertEqual(patch.read_system_uuid(handle.read()), expected)
            self.assertEqual(oct(os.stat(os.path.join(dest, "DMI")).st_mode & 0o777), "0o444")

            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(patch.main(argv), 0)
            self.assertEqual(out.getvalue().strip(), "uuid=%s unchanged" % expected)

    def test_cli_print_mode_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(patch.main(["--uuid-name", "pve-ct-host:1304", "--print"]), 0)
            self.assertEqual(
                out.getvalue().strip(),
                str(uuid.uuid5(uuid.NAMESPACE_DNS, "pve-ct-host:1304")),
            )
            self.assertEqual(os.listdir(tmp), [])

    def test_cli_fails_on_unreadable_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rc = patch.main(["--source", os.path.join(tmp, "nope"),
                                 "--dest-dir", tmp, "--uuid", ASYM])
            self.assertEqual(rc, 1)
            self.assertIn("cannot read", err.getvalue())
            self.assertFalse(os.path.exists(os.path.join(tmp, "DMI")))

CONF_TEMPLATE = """\
arch: amd64
cores: 4
hostname: sunbeam-01
memory: 8192
net0: name=eth0,bridge=pub11,hwaddr=AA:BB:CC:DD:EE:01,ip=192.168.11.11/24,type=veth
rootfs: pve-thin-pool:vm-1201-disk-0,size=40G
swap: 0
unprivileged: 0
{extra}{sections}"""

ENTRY_DMI = ("/var/lib/ansible-pve/dmi/1201/DMI sys/firmware/dmi/tables/DMI "
             "none bind,create=file 0 0")
ENTRY_UUID = ("/var/lib/ansible-pve/dmi/1201/product_uuid sys/class/dmi/id/product_uuid "
              "none bind,create=file 0 0")
ENTRY_UUID_CANONICAL = ("/var/lib/ansible-pve/dmi/1201/product_uuid "
                       "sys/devices/virtual/dmi/id/product_uuid none bind,create=file 0 0")
UUID_1201 = "45c26f8b-97a4-5079-a5f5-a4f544f0f963"

class ConfEntriesTest(unittest.TestCase):
    def write(self, tmp, text):
        path = os.path.join(tmp, "1201.conf")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def read(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def run_tool(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = conf.main(list(args))
        return rc, out.getvalue().strip()

    def apply(self, path):
        return self.run_tool("--conf", path, "--entry", ENTRY_DMI, "--entry", ENTRY_UUID)

    def test_adds_both_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra="", sections=""))
            self.assertEqual(self.apply(path), (0, "changed"))
            text = self.read(path)
            self.assertIn("lxc.mount.entry: " + ENTRY_DMI + "\n", text)
            self.assertIn("lxc.mount.entry: " + ENTRY_UUID + "\n", text)
            self.assertEqual(self.apply(path), (0, "unchanged"))

    def test_no_comment_lines_are_added(self):

        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra="", sections=""))
            self.assertEqual(self.apply(path)[0], 0)
            self.assertNotIn("#", self.read(path))

    def test_snapshot_section_is_byte_identical(self):
        sections = ("\n[u2604-fresh-installed]\narch: amd64\n"
                    "snapname: u2604-fresh-installed\nsnaptime: 1700000000\n")
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra="", sections=sections))
            self.assertEqual(self.apply(path)[0], 0)
            text = self.read(path)
            self.assertTrue(text.endswith(sections))
            active = text.split("\n[", 1)[0]
            self.assertEqual(active.count("lxc.mount.entry"), 2)

    def test_replaces_a_stale_source(self):
        stale = ("lxc.mount.entry: /old/place/DMI sys/firmware/dmi/tables/DMI "
                 "none bind,create=file 0 0\n")
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra=stale, sections=""))
            self.assertEqual(self.apply(path)[0], 0)
            text = self.read(path)
            self.assertEqual(text.count("sys/firmware/dmi/tables/DMI"), 1)
            self.assertNotIn("/old/place/DMI", text)

    def test_unrelated_mount_entries_survive(self):
        other = "lxc.mount.entry: /dev/loop0 dev/osd-block none bind,optional,create=file 0 0\n"
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra=other, sections=""))
            self.assertEqual(self.apply(path)[0], 0)
            self.assertIn(other, self.read(path))

    def test_remove_drops_the_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra="", sections=""))
            self.assertEqual(self.apply(path)[0], 0)
            rc, out = self.run_tool("--conf", path, "--remove",
                                    "--entry", ENTRY_DMI, "--entry", ENTRY_UUID)
            self.assertEqual((rc, out), (0, "changed"))
            self.assertNotIn("lxc.mount.entry", self.read(path))

    def test_absolute_destination_is_refused(self):
        bad = "/var/lib/ansible-pve/dmi/1201/DMI /sys/firmware/dmi/tables/DMI none bind 0 0"
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = conf.main(["--conf", "/dev/null", "--entry", bad])
        self.assertEqual(rc, 1)
        self.assertIn("container-relative", err.getvalue())

    def test_missing_conf_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, out = self.apply(os.path.join(tmp, "absent.conf"))
            self.assertEqual((rc, out), (1, ""))

    def test_stale_managed_mount_is_pruned(self):

        stale = ("lxc.mount.entry: /var/lib/ansible-pve/dmi/1201/product_uuid "
                 "sys/class/dmi/id/product_uuid none bind,create=file 0 0\n")
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra=stale, sections=""))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = conf.main(["--conf", path, "--entry", ENTRY_DMI,
                                "--entry", ENTRY_UUID_CANONICAL,
                                "--prune-source", "/var/lib/ansible-pve/dmi/1201/"])
            self.assertEqual(rc, 0)
            text = self.read(path)
            self.assertNotIn("sys/class/dmi/id/product_uuid", text)
            self.assertIn("sys/devices/virtual/dmi/id/product_uuid", text)
            self.assertEqual(text.count("lxc.mount.entry: /var/lib/ansible-pve"), 2)

    def test_prune_leaves_unmanaged_entries_alone(self):
        other = "lxc.mount.entry: /dev/loop0 dev/osd-block none bind,create=file 0 0\n"
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra=other, sections=""))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                conf.main(["--conf", path, "--entry", ENTRY_DMI, "--entry", ENTRY_UUID,
                           "--prune-source", "/var/lib/ansible-pve/dmi/1201/"])
            self.assertIn("/dev/loop0 dev/osd-block", self.read(path))

    def test_remove_also_strips_a_legacy_identity_comment(self):
        legacy = "# ansible-pve system_uuid=" + UUID_1201 + "\n"
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, CONF_TEMPLATE.format(extra=legacy, sections=""))
            self.assertEqual(self.apply(path)[0], 0)
            self.assertNotIn("# ansible-pve system_uuid=", self.read(path))

REGISTRY_HEADER = "# test registry\n"

class RegistryTest(unittest.TestCase):
    def run_tool(self, *args):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = registry.main(list(args))
        return rc, out.getvalue().strip(), err.getvalue()

    def test_set_merge_and_sort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "registry.conf")
            self.assertEqual(self.run_tool("--file", path, "--set", "1201=" + UUID_1201)[:2],
                             (0, "changed"))
            self.assertEqual(self.run_tool("--file", path, "--set", "1101=" + ASYM)[:2],
                             (0, "changed"))
            text = open(path).read()
            self.assertTrue(text.startswith("#"))
            self.assertEqual([line.split()[0] for line in text.splitlines()
                              if not line.startswith("#")], ["1101", "1201"])
            self.assertEqual(self.run_tool("--file", path, "--set", "1201=" + UUID_1201)[:2],
                             (0, "unchanged"))

    def test_get_and_remove(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "registry.conf")
            self.run_tool("--file", path, "--set", "1201=" + UUID_1201)
            self.assertEqual(self.run_tool("--file", path, "--get", "1201")[:2],
                             (0, UUID_1201))
            self.assertEqual(self.run_tool("--file", path, "--get", "1304")[0], 1)
            self.assertEqual(self.run_tool("--file", path, "--remove", "1201")[:2],
                             (0, "changed"))
            self.assertEqual(self.run_tool("--file", path, "--get", "1201")[0], 1)

    def test_duplicate_uuid_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "registry.conf")
            with open(path, "w") as handle:
                handle.write(REGISTRY_HEADER + "1201 " + UUID_1201 + "\n"
                             "1202 " + UUID_1201 + "\n")
            rc, out, err = self.run_tool("--file", path, "--set", "1203=" + ASYM)
            self.assertEqual(rc, 1)
            self.assertIn("duplicate", err)

    def test_chmod_refused_by_pmxcfs_is_tolerated(self):

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "priv", "ct-system-uuid.conf")
            real_chmod = os.chmod

            def refusing_chmod(target, mode, **kwargs):
                raise OSError(errno.EPERM, "Operation not permitted", target)

            with mock.patch.object(registry.os, "chmod", refusing_chmod):
                rc, out, err = self.run_tool("--file", path, "--set", "1201=" + UUID_1201)
            self.assertEqual((rc, out), (0, "changed"))
            self.assertEqual(registry.read_table(path), {1201: UUID_1201})
            real_chmod(path, 0o644)

    def test_other_chmod_errors_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "registry.conf")

            def broken_chmod(target, mode, **kwargs):
                raise OSError(errno.EIO, "I/O error", target)

            with mock.patch.object(registry.os, "chmod", broken_chmod):
                rc, out, err = self.run_tool("--file", path, "--set", "1201=" + UUID_1201)
            self.assertEqual(rc, 1)
            self.assertIn("I/O error", err)

    def test_malformed_line_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "registry.conf")
            with open(path, "w") as handle:
                handle.write("1201 not-a-uuid\n")
            rc, out, err = self.run_tool("--file", path, "--set", "1203=" + ASYM)
            self.assertEqual(rc, 1)
            self.assertIn("not a canonical UUID", err)

if __name__ == "__main__":
    unittest.main()
