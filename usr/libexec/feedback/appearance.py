#!/usr/bin/env python
# -*- coding: utf-8 -*-

import Foundation as NS
import json
import sys

out = ""
try:
    defaults = NS.NSUserDefaults.standardUserDefaults()
    globalDomain = defaults.persistentDomainForName_(NS.NSGlobalDomain)
    universalAccess = defaults.persistentDomainForName_(u"com.apple.universalaccess")

    output = {
        "appearance.interfaceStyle" : globalDomain.get("AppleInterfaceStyle", u"Default"),
        "appearance.reduceTransparency" : universalAccess.get("reduceTransparency", False),
        "appearance.increaseContrast" : universalAccess.get("increaseContrast", False),
    }

    out = json.dumps(output)
    sys.stdout.write(out)
    sys.stdout.flush()
    sys.exit(0)

except Exception:
    sys.stdout.write(json.dumps({}))
    sys.stdout.flush()
    sys.exit(1)