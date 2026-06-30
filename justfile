deps:
    mix deps.get

test:
    mix test

format:
    mix format --migrate

readmix:
    mix rdmx.update README.md

_libdev_check:
    mix libdev.check

_git_status:
    git status

docs: readmix
    mix docs --warnings-as-errors

check: format readmix _libdev_check _git_status
