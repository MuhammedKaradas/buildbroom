# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through GitHub instead:
**Security → Report a vulnerability** on this repository
([direct link](https://github.com/MuhammedKaradas/buildbroom/security/advisories/new)).

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get an answer within a
week. Once a fix is released, you'll be credited in the advisory unless you'd rather not be.

## Supported versions

Only the latest release gets security fixes.

## What's in scope

buildbroom deletes files, so these matter most:

- **Deleting outside the rules:** anything that makes buildbroom remove a path that is not a documented cache or a
  build folder that passes every check (marker file, `git check-ignore`, age). For example a crafted folder name,
  a junction or symlink that gets followed, or a path that escapes a root.
- **Command injection:** a file or folder name, config value or environment variable that ends up being run as a
  command (buildbroom calls `cmd /c rmdir`, `git`, `npm`, `dotnet` and others).
- **Elevated or scheduled runs:** anything that lets another user or a project's files influence a run started by
  someone else, or with admin rights.
- **Release packages:** the zip and its SHA256 file on the Releases page.

A wrong deletion that is just a missing rule (not an attack) is a bug; please report it with the
"Something was deleted" issue template.
