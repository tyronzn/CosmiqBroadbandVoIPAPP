# Third-party components

## bcg729 (G.729 codec) — NOT included in this repository

G.729 support is provided via **bcg729** by Belledonne Communications, licensed
under the **GNU General Public License v3 (GPLv3)**.

bcg729 source is **not redistributed** in this repository. To build real G.729
support, fetch it yourself:

```bash
git clone https://github.com/BelledonneCommunications/bcg729.git \
  android/app/src/main/cpp/bcg729
```

When present, CMake compiles it into `libcosmiqg729.so`. When absent, the app
builds with a stub and G.729 is simply not offered (µ-law / A-law still work).

> ⚠️ **Licensing note:** bcg729 is GPLv3. Distributing a built binary that links
> it brings the combined work under GPLv3, which is incompatible with this
> repository's proprietary license. For a closed-source / commercial product,
> obtain a commercial license for bcg729 from Belledonne Communications, or do
> not ship G.729.

## Flutter / Dart packages

Standard pub.dev packages are declared in `pubspec.yaml` (http, dio, provider,
flutter_secure_storage, shared_preferences, just_audio, permission_handler,
intl, flutter_contacts, connectivity_plus, uuid, logger, url_launcher). Each is
under its own license (predominantly BSD/MIT/Apache-2.0).
