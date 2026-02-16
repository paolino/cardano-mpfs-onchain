# Development

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [just](https://github.com/casey/just) (optional, for convenience recipes)

## Building

Build the Plutus blueprint (`plutus.json`) in a reproducible Nix sandbox:

```sh
just build
# or directly:
nix build
```

The output is a symlink `result` pointing to the produced `plutus.json`.

## Development shell

Drop into a shell with `aiken` available:

```sh
just develop
# or directly:
nix develop
```

## Testing

Run the Aiken test suite (requires aiken in PATH or from `nix develop`):

```sh
just test
```

## Justfile recipes

| Recipe        | Description                              |
| ------------- | ---------------------------------------- |
| `just build`  | Build `plutus.json` via Nix              |
| `just develop`| Enter dev shell with `aiken`             |
| `just test`   | Run `aiken check` tests                  |

## How the Nix build works

The flake pre-fetches the three Aiken dependencies (`stdlib`, `fuzz`,
`merkle-patricia-forestry`) using `fetchFromGitHub` and populates
`build/packages/` before running `aiken build`. This avoids network
access inside the Nix sandbox.
