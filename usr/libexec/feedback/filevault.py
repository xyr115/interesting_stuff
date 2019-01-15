#!/usr/bin/env python
# -*- coding: utf-8 -*-

# Imports
import json
import plistlib
import subprocess
import sys

# Constants
kCoreStorageLogicalVolumeConversionState = 'CoreStorageLogicalVolumeConversionState'
kCoreStorageLogicalVolumeFamilyEncryptionType = 'CoreStorageLogicalVolumeFamilyEncryptionType'
kCoreStorageLogicalVolumeSparse = 'CoreStorageLogicalVolumeGroupSparse'
kMemberOfCoreStorageLogicalVolumeFamily = 'MemberOfCoreStorageLogicalVolumeFamily'
kMemberOfCoreStorageLogicalVolumeGroup = 'MemberOfCoreStorageLogicalVolumeGroup'


# Implementation
def _diskutil_cs_info(plist=False, target='/'):
    cmd = ['diskutil', 'coreStorage', 'information']
    cmd.append('-plist') if plist else None
    cmd.append(target) if isinstance(target, (str, unicode)) else None
    try:
        ret = subprocess.check_output(cmd)
    except Exception:
        return {}

    return plistlib.readPlistFromString(ret) if plist else str(ret)


def _diskutil_cs_list(plist=False):
    cmd = ['diskutil', 'coreStorage', 'list']
    cmd.append('-plist') if plist else None
    try:
        ret = subprocess.check_output(cmd)
    except Exception:
        return {}

    return plistlib.readPlistFromString(ret) if plist else str(ret)


def _diskutil_list(plist=False):
    cmd = ['diskutil', 'list']
    cmd.append('-plist') if plist else None
    try:
        ret = subprocess.check_output(cmd)
    except Exception:
        return {}

    return plistlib.readPlistFromString(ret) if plist else str(ret)


def is_fv_sparse():
    try:
        lvg_uuid = _diskutil_cs_info(plist=True).get(kMemberOfCoreStorageLogicalVolumeGroup, None)
        lvg = _diskutil_cs_info(plist=True, target=lvg_uuid)
        ret = lvg.get(kCoreStorageLogicalVolumeSparse, None)
        return bool(ret)
    except Exception:
        return False


def is_fv_finised():
    try:
        state = _diskutil_cs_info(plist=True).get(kCoreStorageLogicalVolumeConversionState, '')
        return bool(is_fv_turned_on() and 'Complete' in state)
    except Exception:
        return None


def is_fv_turned_on():
    try:
        lvf_uuid = _diskutil_cs_info(plist=True).get(kMemberOfCoreStorageLogicalVolumeFamily, None)
        lvf = _diskutil_cs_info(plist=True, target=lvf_uuid)
        ret = lvf.get(kCoreStorageLogicalVolumeFamilyEncryptionType, '')
        return bool(not 'None' in ret)
    except Exception:
        return None


def was_fv_adopted_at_macbuddy():
    try:
        ret = subprocess.check_output(['syslog', '-F', 'xml', '-d', '/var/log/DiagnosticMessages', '-k', 'com.apple.message.domain', 'com.apple.macbuddy.fvadopted'])
        msgs = plistlib.readPlistFromString(ret)
        msg = msgs[0] if msgs else {}
        return bool(msg.get('com.apple.message.domain', False) == 'com.apple.macbuddy.fvadopted')
    except Exception:
        return None


# Go!
if __name__ == "__main__":

    try:
        data = {
            'filevault_is_finised': is_fv_finised(),
            'filevault_is_sparse': is_fv_sparse(),
            'filevault_is_turned_on': is_fv_turned_on(),
            'filevault_was_adopted_at_macbuddy': was_fv_adopted_at_macbuddy(),
        }

        out = json.dumps(data)
    except Exception:

        sys.stdout.write(json.dumps({}))
        sys.stdout.flush()
        sys.exit(1)
    else:
        sys.stdout.write(out)
        sys.stdout.flush()
        sys.exit(0)
