#!/usr/bin/env python3
"""Converts the Android string resources into iOS Localizable.strings.

Same keys on both platforms, so `L("tool_trim")` on iOS is R.string.tool_trim
on Android. Keys missing from a translation are filled with English (Android
falls back to values/ automatically; iOS returns the raw key instead).

Usage: convert_strings.py <android res dir> <ios Resources dir>
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ios_strings import LANGS, S as IOS, INFOPLIST  # noqa: E402

FOLDERS = {
    "values": "en", "values-es": "es", "values-pt-rBR": "pt-BR", "values-fr": "fr",
    "values-de": "de", "values-ar": "ar", "values-hi": "hi", "values-in": "id",
}

# Platform words. Brand names stay in Latin script in every Android translation,
# so a literal replacement is safe across languages.
SUBS = [
    ("Google Play Billing", "App Store"),
    ("Google Play", "App Store"),
    ("Play Store", "App Store"),
    ("Play Console", "App Store Connect"),
    ("Android", "iOS"),
]

# Android strings whose meaning does not carry over get an iOS key instead;
# these are dropped so nobody uses the Android wording by mistake.
DROP = {"developer_play_url", "developer_market_uri", "privacy_policy_url"}


def android_text(el):
    raw = "".join(el.itertext())
    if len(raw) >= 2 and raw.startswith('"') and raw.endswith('"'):
        raw = raw[1:-1]
    else:
        raw = re.sub(r"\s+", " ", raw).strip()
    out, i = [], 0
    while i < len(raw):
        c = raw[i]
        if c == "\\" and i + 1 < len(raw):
            n = raw[i + 1]
            out.append({"n": "\n", "t": "\t", "'": "'", '"': '"', "@": "@", "?": "?", "\\": "\\"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    text = "".join(out)
    # printf: %1$s -> %1$@, %1$d -> %1$ld, plain %s/%d too
    text = re.sub(r"%(\d+\$)?s", lambda m: "%" + (m.group(1) or "") + "@", text)
    text = re.sub(r"%(\d+\$)?d", lambda m: "%" + (m.group(1) or "") + "ld", text)
    for a, b in SUBS:
        text = text.replace(a, b)
    return text


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def load(path):
    root = ET.parse(path).getroot()
    out = {}
    for el in root.findall("string"):
        if el.get("translatable") == "false" and not path.endswith("values/strings.xml"):
            continue
        name = el.get("name")
        if name in DROP:
            continue
        out[name] = android_text(el)
    return out


def main(res, dest):
    english = load(os.path.join(res, "values", "strings.xml"))
    report = []
    for folder, lang in FOLDERS.items():
        path = os.path.join(res, folder, "strings.xml")
        table = dict(english)
        if lang != "en" and os.path.exists(path):
            table.update(load(path))
        idx = LANGS.index(lang)
        for key, values in IOS.items():
            table[key] = values[idx]
        lproj = os.path.join(dest, f"{lang}.lproj")
        os.makedirs(lproj, exist_ok=True)
        with open(os.path.join(lproj, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write(f"/* ScreenRec Pro — {lang}. Generated from Android {folder}/strings.xml + iOS keys. */\n\n")
            for k in sorted(table):
                f.write(f'"{k}" = "{escape(table[k])}";\n')
        with open(os.path.join(lproj, "InfoPlist.strings"), "w", encoding="utf-8") as f:
            f.write("/* Permission prompts */\n")
            f.write(f'"CFBundleDisplayName" = "ScreenRec Pro";\n')
            for k, values in INFOPLIST.items():
                f.write(f'"{k}" = "{escape(values[idx])}";\n')
        report.append((lang, len(table)))
    for lang, n in report:
        print(f"{lang:6} {n} strings")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
