# Contributing

Thanks for your interest in opencast.

## How changes land here

This repository is a published mirror of a private source tree. Development happens in that tree, and its contents are published here through an audited sync, so `main` moves in sync commits rather than through merges of individual pull requests.

Pull requests are welcome and are read carefully. When one is accepted it is merged here for the record, the change is carried into the private tree, and it comes back in a later sync with credit preserved. That later sync may rework the code to fit the surrounding design, so expect the final shape of your change to differ from the diff you opened.

## Before you open a pull request

- For anything larger than a small fix, open an issue first so the approach can be agreed before you spend time on it.
- Keep each pull request to one feature or fix.
- Match the surrounding code: Swift 6 language mode, SwiftUI and Observation, small single-purpose files, no third-party dependencies.
- The README's "Build from source" section covers building and running the tests.

## Continuous integration

Apple CI and Server CI run on every pull request. Runs from first-time contributors wait for maintainer approval before they start, which is normal.

## Support

Need help using the app? Visit [support.opencast.mobile](https://support.opencast.mobile). For bugs and feature ideas, [open an issue](https://github.com/connlark/opencast/issues).
