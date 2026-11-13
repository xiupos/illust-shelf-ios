# Illust Shelf for iOS

Browse and organize illustrations in a folder, with tags, sources, and notes. For iPhone and iPad.

The metadata is in a JSON file next to each image, in the [illust-sidecar](https://github.com/xiupos/illust-sidecar) format, so a folder works with any app that reads it.

## Building

Open `IllustShelfApp.swiftpm` in Swift Playgrounds on an iPad (iPadOS 26 or later) and run it. It has no dependencies.

## Using

Choose a folder of images, for example one that a sync app keeps up to date. The app reads the images under it, at any depth.

- **Library** shows every image, newest first. Add images with +, or drop them on it; they are copied into the folder. Pull down to reload after the folder has changed.
- **Tags** shows the tags in use, by namespace: `creator:Name` is under Creator.
- **Search** finds images by title, note, or tag, and tags by name.
- Tap an image to look at it: swipe for the next, pinch or double tap to zoom, tap to hide the bars. Info (ⓘ) edits its title, note, tags, and sources, and saves as you type.

With a keyboard: ⌘R reloads, ⌘O chooses a folder, ⌘V pastes an image; while looking at an image, ← and → page, ⌘I shows Info, ⌘⌫ deletes it, and Esc closes it.

## See also

- [illust-shelf-gtk](https://github.com/xiupos/illust-shelf-gtk): Illust Shelf for GNOME
- [illust-sidecar](https://github.com/xiupos/illust-sidecar): the metadata format

## License

MIT
