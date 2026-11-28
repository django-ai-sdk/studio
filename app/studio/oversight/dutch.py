"""Dutch personal data, secrets, refusals and injections for Studio's oversight policy.

The SDK ships only what holds in every country and language. A host adds its own
country kinds with `register_pii_kind`, and its own words by extending the SDK's
pattern tables. This module does both for Dutch.

The kinds are registered when this module is imported. The SDK imports every app's
`oversight` module at startup, and `studio.oversight` imports this one, so stored
policy definitions can name the kinds too.
"""

from __future__ import annotations

import re

from django_ai_sdk.oversight import INJECTION_PATTERNS, SECRET_PATTERNS, register_pii_kind
from django_ai_sdk.oversight.patterns import REFUSAL_PATTERNS

_SEP = r"[\s\-./​‌‍⁠﻿]"


def bsn_ok(value: str) -> bool:
    """Dutch BSN 11-check, the last digit weighted -1."""
    digits = re.sub(r"\D", "", value)
    if len(digits) == 8:
        digits = "0" + digits
    if len(digits) != 9 or digits == "000000000":
        return False
    weights = [9, 8, 7, 6, 5, 4, 3, 2, -1]
    return sum(int(d) * w for d, w in zip(digits, weights, strict=True)) % 11 == 0


BSN = (
    rf"(?<!\d)(?:\d{{9}}|\d{{4}}{_SEP}\d{{2}}{_SEP}\d{{3}}|\d{{3}}{_SEP}\d{{3}}{_SEP}\d{{3}})(?!\d)"
)

# One in eleven invoice or order numbers passes the 11-check, so a number right after
# such a label is not a BSN. Only the label itself counts: "factuur 111222333" leaves a
# real BSN unmasked for the model, which is the trade.
INVOICE_LABEL = (
    r"(?i)\b(?:invoice|factuur|order|bestel|bestelling)"
    r"(?:nummer|nr|number)?(?:\s*(?:no|nr|number|nummer|#)\.?)?\s*[:#]?\s*$"
)

# Any grouping of a national number, but not a date followed by a time (03-11-2026 14:00).
PHONE_NL = (
    rf"(?<![\w+])(?!\d\d([-./])\d\d\1\d{{4}}\b)"
    rf"(?:\(0\d{{1,3}}\)\s?(?:{_SEP}?\d){{6,8}}|0(?:{_SEP}?\d){{9}})(?!\d)"
)

# Dutch postcodes never use SA, SD or SS. The rest are units and words that follow a
# four-digit number in ordinary text: 4096 MB, HTTP 8080 OK, In 1984 WE met.
NOT_POSTCODE_LETTERS = (
    "SA SD SS KB MB GB TB PB OK AM PM AD BC CE HZ MS PX PT EM KM CM MM KG MG ML HP KW MW GW "
    "TV PC VS AN AS AT BE BY DO GO HE IF IN IS IT ME MY NO OF ON OR SO TO UP US WE"
).split()
POSTCODE_NL = rf"\b[1-9]\d{{3}}\s?(?!(?:{'|'.join(NOT_POSTCODE_LETTERS)})\b)[A-Z]{{2}}\b"

# An address spelled out in Dutch: "sanne punt devries apenstaartje gmail punt com".
_AT_NL = (
    r"\s{0,3}(?:[\[({<]\s{0,3}(?i:at|@|apenstaartje)\s{0,3}[\])}>]|\s(?i:apenstaartje)\s)\s{0,3}"
)
_DOT_NL = r"(?:\.|\s{0,3}(?:[\[({<]\s{0,3}(?i:dot|punt|\.)\s{0,3}[\])}>]|\s(?i:dot|punt)\s)\s{0,3})"
SPELLED_EMAIL_NL = (
    rf"(?<![\w+-])[\w+-]{{1,64}}+(?:{_DOT_NL}[\w+-]{{1,64}}+){{0,4}}"
    rf"{_AT_NL}[\w-]{{1,63}}+(?:{_DOT_NL}[\w-]{{1,63}}+){{1,8}}\b"
)

register_pii_kind("bsn", BSN, verify=bsn_ok, not_after=INVOICE_LABEL)
register_pii_kind("phone_nl", PHONE_NL)
register_pii_kind("postcode_nl", POSTCODE_NL)
register_pii_kind("email_spelled_nl", SPELLED_EMAIL_NL)

DUTCH_PII_KINDS = ["bsn", "phone_nl", "postcode_nl", "email_spelled_nl"]

_PASSWORD_VALUE = (
    r"""(?:(["'])[^"'\n]{6,128}\1|(?=\S*?(?:\d|[!@#$%^&*_+=~|\\/<>{}\[\]-]\S))\S{6,})"""
)
SECRET_PATTERNS_EN_NL = {
    **SECRET_PATTERNS,
    "password_assignment_nl": r"(?i)(?<![a-z0-9])wachtwoord[\"']?\s*[:=]\s*" + _PASSWORD_VALUE,
}

REFUSAL_PATTERNS_EN_NL = [
    *REFUSAL_PATTERNS,
    r"\b(?:ik kan (?:je )?(?:daar )?niet (?:mee )?helpen|dat kan ik niet)",
]

INJECTION_PATTERNS_EN_NL = {
    **INJECTION_PATTERNS,
    "override": [
        *INJECTION_PATTERNS["override"],
        r"\bnegeer\s{1,4}(?:(?:alle|de|je|jouw|eerdere|vorige|bovenstaande)\s{1,4}){0,3}"
        r"(?:instructies|regels)\b",
    ],
}
