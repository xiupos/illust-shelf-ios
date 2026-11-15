# illust-shelf-ios

A file-based illustration library for iPhone and iPad. Your images stay in an ordinary folder, and their titles, tags, sources, and notes in a JSON file next to each one (`foo.png.json` for `foo.png`), in the [illust-sidecar](https://github.com/xiupos/illust-sidecar) format. There is no database: any program can read the folder, iCloud Drive or any other sync can carry it, and [illust-shelf-gtk](https://github.com/xiupos/illust-shelf-gtk) opens the same one.

## Usage

Choose a folder of images, for example one that a sync app keeps up to date. The app reads the images under it, at any depth.

- **Library** shows every image, newest first. Add images with +, or drop them on it; they are copied into the folder. Pull down to reload after the folder has changed.
- **Search** shows the tags in use by namespace (`creator:Name` is under Creator) until you type, then the tags and the images whose title, note, or tags match.
- **Tap an image** to look at it: swipe for the next, pinch or double tap to zoom, tap to hide the bars. Info (ⓘ) edits its title, note, tags, and sources, and saves as you type.

With a keyboard: ⌘R reloads, ⌘O chooses a folder, ⌘V pastes an image; while looking at an image, ← and → page, ⌘I shows Info, ⌘⌫ deletes it, and Esc closes it.

## Building

Open `IllustShelfApp.swiftpm` in Swift Playgrounds on an iPad (iPadOS 26 or later) and run it. It has no dependencies.

## See also

- [illust-shelf-gtk](https://github.com/xiupos/illust-shelf-gtk): Illust Shelf for GNOME, with the behaviour the apps share in its `spec/SPEC.md`
- [illust-sidecar](https://github.com/xiupos/illust-sidecar): the metadata format

## License

[MIT](LICENSE)
