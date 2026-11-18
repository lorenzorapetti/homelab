mod tf 'infrastructure/mod.just'
mod talos 'talos/mod.just'
mod bootstrap 'bootstrap/mod.just'

[private]
default:
    @just --list --list-submodules
