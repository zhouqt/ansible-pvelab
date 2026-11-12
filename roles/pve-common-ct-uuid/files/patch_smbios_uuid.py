#!/usr/bin/env python3

import argparse
import os
import sys
import uuid

SMBIOS_TYPE_SYSTEM_INFORMATION = 1
SMBIOS_TYPE_END_OF_TABLE = 127

SYSTEM_UUID_OFFSET = 0x08
SYSTEM_UUID_MIN_LENGTH = 0x19

INVALID_UUIDS = {
    "00000000-0000-0000-0000-000000000000",
    "ffffffff-ffff-ffff-ffff-ffffffffffff",
}

class PatchError(Exception):
    pass

def parse_uuid(value):

    text = (value or "").strip().lower()
    if text in INVALID_UUIDS:
        raise PatchError("refusing to use the reserved UUID %s" % text)
    try:
        parsed = uuid.UUID(text)
    except ValueError as exc:
        raise PatchError("not a valid UUID %r: %s" % (value, exc))
    if str(parsed) != text:
        raise PatchError("UUID %r is not in canonical 8-4-4-4-12 form" % value)
    return parsed

def uuid_from_name(name):

    text = (name or "").strip()
    if not text:
        raise PatchError("--uuid-name must not be empty")
    return parse_uuid(str(uuid.uuid5(uuid.NAMESPACE_DNS, text)))

def iter_structures(table):

    size = len(table)
    pos = 0
    while pos + 4 <= size:
        stype = table[pos]
        length = table[pos + 1]
        if length < 4 or pos + length > size:
            raise PatchError(
                "malformed SMBIOS structure at offset %d (type %d, length %d)"
                % (pos, stype, length)
            )
        yield pos, stype, length
        if stype == SMBIOS_TYPE_END_OF_TABLE:
            return

        cursor = pos + length
        while True:
            end = table.find(b"\x00", cursor)
            if end < 0:
                raise PatchError("unterminated SMBIOS string set at offset %d" % cursor)
            if end == cursor:
                cursor = end + 1
                break
            cursor = end + 1
        pos = cursor

def find_system_information(table):

    for offset, stype, length in iter_structures(table):
        if stype == SMBIOS_TYPE_SYSTEM_INFORMATION:
            if length < SYSTEM_UUID_MIN_LENGTH:
                raise PatchError(
                    "SMBIOS Type 1 structure is only %d bytes long, need >= %d"
                    % (length, SYSTEM_UUID_MIN_LENGTH)
                )
            return offset
    raise PatchError("SMBIOS table has no Type 1 (System Information) structure")

def patch_table(table, system_uuid):

    if len(table) < SYSTEM_UUID_MIN_LENGTH:
        raise PatchError("SMBIOS table is too short (%d bytes)" % len(table))
    offset = find_system_information(table)
    start = offset + SYSTEM_UUID_OFFSET
    end = start + 16
    patched = bytearray(table)

    patched[start:end] = system_uuid.bytes_le
    return bytes(patched)

def read_system_uuid(table):

    offset = find_system_information(table)
    start = offset + SYSTEM_UUID_OFFSET
    return str(uuid.UUID(bytes_le=table[start:start + 16]))

def write_if_changed(path, payload, mode=0o444):

    try:
        with open(path, "rb") as handle:
            if handle.read() == payload:
                os.chmod(path, mode)
                return False
    except FileNotFoundError:
        pass
    directory = os.path.dirname(path)
    tmp = os.path.join(directory, ".%s.tmp" % os.path.basename(path))
    with open(tmp, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return True

def build_parser():
    parser = argparse.ArgumentParser(description="Give one LXC container its own SMBIOS system UUID.")
    parser.add_argument("--source", default="/sys/firmware/dmi/tables/DMI",
                        help="host DMI table to copy (default: %(default)s)")
    parser.add_argument("--dest-dir",
                        help="directory receiving DMI and product_uuid")
    parser.add_argument("--uuid", help="explicit system UUID to write")
    parser.add_argument("--uuid-name",
                        help="derive the UUID with uuid5(NAMESPACE_DNS, NAME)")
    parser.add_argument("--print", action="store_true",
                        help="only print the resolved UUID, write nothing")
    return parser

def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.uuid and args.uuid_name:
        parser.error("--uuid and --uuid-name are mutually exclusive")
    if not args.uuid and not args.uuid_name:
        parser.error("one of --uuid or --uuid-name is required")
    if not args.print and not args.dest_dir:
        parser.error("--dest-dir is required unless --print is used")

    try:
        system_uuid = parse_uuid(args.uuid) if args.uuid else uuid_from_name(args.uuid_name)
        if args.print:
            print(str(system_uuid))
            return 0

        try:
            with open(args.source, "rb") as handle:
                source = handle.read()
        except OSError as exc:
            raise PatchError("cannot read %s: %s" % (args.source, exc))

        patched = patch_table(source, system_uuid)
        os.makedirs(args.dest_dir, mode=0o755, exist_ok=True)
        dmi_changed = write_if_changed(os.path.join(args.dest_dir, "DMI"), patched)
        uuid_changed = write_if_changed(
            os.path.join(args.dest_dir, "product_uuid"),
            ("%s\n" % system_uuid).encode("ascii"),
        )
    except PatchError as exc:
        print("patch_smbios_uuid: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("patch_smbios_uuid: %s" % exc, file=sys.stderr)
        return 1

    print("uuid=%s %s" % (system_uuid, "changed" if dmi_changed or uuid_changed else "unchanged"))
    return 0

if __name__ == "__main__":
    sys.exit(main())
