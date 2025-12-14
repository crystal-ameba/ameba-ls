# ameba-ls

Language server for the [Ameba](https://github.com/crystal-ameba/ameba) linter for Crystal lang.

Supports reporting issues while typing, and correcting issues via code actions. Does not require `ameba` be installed.

![](/assets/output.gif)

## Installation

Each release corresponds to Ameba and Crystal lang releases.

| `ameba-ls` | Ameba | Crystal Lang |
|------------|-------|--------------|
|      0.1.0 | 1.6.4 |       1.15.1 |

The latest release can be downloaded from GitHub or built from source.

### Build from source

```sh
$ git clone https://github.com/crystal-ameba/ameba-ls
$ cd ameba-ls
$ make
$ cp ./bin/ameba-ls ~/.local/bin # or somewhere else in PATH
```

## Usage

### Zed

The latest version of the [Zed](https://zed.dev) [Crystal extension](https://zed.dev/extensions/crystal) has support for `ameba-ls` if it's installed in `PATH`.

### Sublime

Install the Sublime [LSP](https://github.com/sublimelsp/LSP) package and configure it to use `ameba-ls`:

```json
{
  "clients": {
    "ameba-ls": {
      "command": [
        "ameba-ls"
      ],
      "selector": "source.crystal",
      "enabled": true,
    },
  },
}
```

## Contributing

1. Fork it (<https://github.com/crystal-ameba/ameba-ls/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Margret Riegert](https://github.com/nobodywasishere) - creator and maintainer
