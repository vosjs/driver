# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability. Report it privately through [GitHub Security Advisories](https://github.com/vosjs/driver/security/advisories/new). You will get an acknowledgement within a few days and updates until a fix ships.

## Scope

The helper asks for Screen Recording, and for Accessibility when it reads element bounds. What it does with them is narrow on purpose, and a way around any of these is in scope:

- the recording holding pixels of an application other than the one asked for
- the helper learning what was typed, or reading text out of an application, at any layer
- the system pointer appearing in the recording
- the helper writing outside the directory it was given, or sending anything over a network
- a recording that keeps running after the process that started it is gone
- `@vosjs/driver` running a binary other than the helper its platform package carries, without `VOS_DRIVER_PATH` being set

Out of scope: what is visible in the window you chose to record. The recording is of that window, as it is.

Issues in the hosted platform at vos.so go to security@vos.so, as https://vos.so/.well-known/security.txt says.

## Supported versions

Pre-1.0: only the latest published version receives security fixes.
