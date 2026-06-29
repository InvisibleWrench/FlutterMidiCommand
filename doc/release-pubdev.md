# Pub.dev release order

Use [tool/publish_pubdev.ps1](/c:/Users/Morten/Code/FlutterMidiCommand/tool/publish_pubdev.ps1:1) to publish or dry-run a single package without manually moving `pubspec_overrides.yaml`.

## Dry-run commands

Run these from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_platform_interface
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_android
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_darwin
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_linux
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_web
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_windows
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_ble
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command
```

## Publish order

Publish in this order:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_platform_interface -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_android -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_darwin -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_linux -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_web -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_windows -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command_ble -Publish
powershell -ExecutionPolicy Bypass -File .\tool\publish_pubdev.ps1 flutter_midi_command -Publish
```

## Important notes

- `pubspec_overrides.yaml` files are intentionally generated for local Melos workspace resolution and are not tracked in Git.
- Wait until each published dependency is visible on pub.dev before moving to packages that depend on it.
- `flutter_midi_command_platform_interface` must be live before `android`, `darwin`, `linux`, `web`, `windows`, and `ble`.
- The root `flutter_midi_command` package must wait until `android`, `darwin`, `linux`, `web`, and `windows` version `1.0.x` are live on pub.dev.
- `flutter_midi_command_ble` is independent of the root package and can be published before or after the root package, but it still depends on `flutter_midi_command_platform_interface`.
- The helper script temporarily hides `pubspec_overrides.yaml` when present, runs `dart pub publish` or `dart pub publish --dry-run`, and restores the override file afterward.
- The root package is currently version `1.0.1` in [pubspec.yaml](/c:/Users/Morten/Code/FlutterMidiCommand/pubspec.yaml:4). Pub.dev previously had `0.5.4`, so `1.0.1` is a valid release, but it will continue to show a version-jump hint during dry-run.
