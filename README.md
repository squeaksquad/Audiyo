Installation Instructions:

1. Drag Application “Audiyo” to the Applications shortcut.

2. Drag “Audiyo Library - Abridged” to the /Users/currentUser/ folder and rename it so the folder is called “.Audiyo Library”. This period at the beginning will hide the folder from the user, and it’s the first place the application looks on launch for the library folder.

	This custom testing installer features an abridged version of the library since otherwise it would be around 32GB.

3. The app prefers fast access to files so running them from a server dependent on 1Gbps networking may be too slow and lead to excessive loading or crashes. It’s preferred to point to a library folder from a local SSD.

Use Instructions:

1. The library will first scan the default directory (mentioned above), then it will look for the last loaded library, and short of that there is a “Load Library Folder” button in the bottom left that prompts the user (Staff access only, not student) for the labadmin password so they can designate a folder.

2. The audio device selector will pull from any available CoreAudio devices but it doesn’t like a device with truly excessive channel counts (256 is way too many), so 12-32 channels wide will work fine, 64 might also be okay but I haven’t tested that.

3. There is a “Reset CoreAudio” button to the right of the Audio Device selector and it will scan for changes in the Core Audio devices. This is helpful when trying to adjust sample rate.

4. There is an error that shows up in red text at the bottom of the screen if the Core Audio device is at a different sample rate from the selected files. Since the mix library we’re using is at 44.1kHz, the audio device should be at 44.1kHz.

5. This app is meant to be used in a “pitch and catch” configuration, where the student opens the app and selects “Pro Tools | HDX” as the Audio Device, then sets up an audio interface with their laptop to “catch” the output of the console mix. Pro Tools should NOT be open on the “pitch” machine (the studio computer), since then it will take the HDX driver away from Core Audio selection.

6. The app remembers the last selected Audio Device, so on startup it should already be ready for song selection by the student user.

7. There is a “Shortcuts” button next to the Audio Device selector that lists the available keyboard shortcuts. They are as follows:

	•	CMD+(1-9); Add marker

	•	(1-9); Go to marker

	•	0; Play from start (or loop)

	•	Space bar; Play/Pause

	•	I; Set Loop In

	•	O; Set Loop Out

	•	L; Toggle loop on/off

	•	CMD+Shift+L; Reset loop region

9. The loaded library folder shows up on the left side bar and the 12 track or 8 track songs libraries can be expanded to show individual songs. Simply click on the song name to load it (or to reset all markers).

10. If any issues come up, restart the app or reset Core Audio and re-load the song. Issues are infrequent but many device changes can become an issue.
