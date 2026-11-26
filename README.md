# System History

A tiny macOS app that shows live CPU, GPU and memory history graphs in a small
floating window, like Activity Monitor's GPU History window, but for all three
and without Activity Monitor running.

- **CPU**: total load, green = user, red = system
- **GPU**: device utilization (the same IOKit counter Activity Monitor uses)
- **Memory**: blue = app, orange = wired, yellow = compressed (together: "Memory Used")

Samples once per second and keeps about 3 minutes of history. The window floats
above other windows, appears on all Spaces, and remembers its size and position.
There's no Dock icon. A menu bar icon has Show/Hide, Keep on Top, and Quit.

## Build

Needs the Xcode command line tools (`swiftc`). No Xcode project.

```bash
./build.sh
open "System History.app"
```

To run it all the time, copy `System History.app` into `/Applications` and add it
under System Settings → General → Login Items.
