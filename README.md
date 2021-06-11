# Homebrew JSON Installer

The `brew json` command allows for formulae to be installed using the bottle API available on https://formulae.brew.sh/.

To use, first tap this repository:

```
brew tap homebrew/json
```

Then, use `brew json` with either a name of a formula in [Homebrew/homebrew-core](https://github.com/Homebrew/homebrew-core) or a path/URL to a JSON file:

```sh
# Using the formula name
brew json hello

# Using a URL
brew json https://formulae.brew.sh/api/bottle/hello.json
```
