# mpv-sub-select

This script allows you to configure advanced subtitle track selection based on the current audio track and the names and language of the subtitle tracks. The script will automatically disable itself when mpv is started with `--sid` not set to `auto`, or when `--track-auto-selection` is disabled.
There is also experimental mode which allows [audio selection](#audio-selection) as well.

## Configuration

Configuration is done in the `sub-select.json` file, stored in the `~~/script-opts/` config directory.

### Syntax

The syntax and available options are as follows:

```json
[
    {
        "alang": "jpn",                         // optional
        "slang": "eng",                         // REQUIRED!!!
        "blacklist": [ "sign" ],                // optional
        "whitelist": [ "english", "song" ],     // optional
        "condition": "sub.codec == 'ass'",      // optional
        "secondary_slang": ["por", "ita?"],     // optional
        "secondary_blacklist": [ "sign" ],      // optional
        "secondary_whitelist": [ "brazilian", "song" ],         // optional
        "secondary_condition": "secondary_sub.codec == 'ass'",  // optional
        "sub_visibility": true,                 // optional
        "secondary_sub_visibility": false       // optional
    }
]
```

`slang` is the only setting which is required to be defined in every preference section. All other settings are optional.
A preference section is defined between `{` and `}`, as the one seen above.

`alang` and `slang` are the language codes of the audio and subtitle tracks,
while `blacklist` and `whitelist` are filters that can be used to choose subtitle tracks based on their track names.
For a track to be selected it must match any entry in the `whitelist` and must not match any entry in the `blacklist`.

`alang` and `slang` can also be arrays of valid codes to allow matching with multiple language codes.
If multiple `slang` languages are included, then the first code to match to a track will be the one used.
If `alang` is not defined it will match to any language.

**Do not use uppercase characters for any options unless using [patterns](#string-matching).**

All titles are converted to lowercase automatically to allow more matches.

`condition` is an optional lua expression that can be used to evaluate whether or not the subtitle should be selected.
This expression will be run for every subtitle that passes the other filters. The `sub` variable contains the subtitle
track entry and `audio` contains the audio track entry. See the [track-list property](https://mpv.io/manual/master/#command-interface-track-list)
for what fields are available. The `mp`, `mp.msg`, and `mp.utils` modules are avaialble as `mp`, `msg`, and `utils`, respectively.
If no audio or sub track is being compared (which only happens if you set alang or slang to `no`) then `audio` or `sub` will evaluate to `nil`.

`secondary_slang`, `secondary_blacklist`, `secondary_whitelist` and `secondary_condition` only apply for the selection of secondary subtitles.
They work the same as their counterparts.
The selection of secondary subtitles always occurs after the selection of the audio track and primary subtitles, so `condition` can't access the `secondary_sub` variable, but `secondary_condition` has access to `audio`, `sub` and `secondary_sub`.
No secondary subtitles will be selected, if `secondary_slang` is not set or matched, or no matching primary subtitle is selected (`no` still counts as a selectection).

`sub_visibility` and `secondary_sub_visibility` set the visibility of the primary and secondary subtitles.
Be aware that these might be overwritten by the mpv-native config options `sub-visibility` and `secondary-sub-visibility`.
The subtitles can be toggled between visible and hidden by using the mpv-defined shortcut keys (by default `v` for primary subtitles and `Alt+v` for secondary ones).

### String Matching

All matching is done using the lua `string.find` function, so supports [patterns](https://www.lua.org/manual/5.1/manual.html#5.4.1). For example `eng?` could be used instead of `eng` so that the DVD language code `en` is also matched.

**The characters `^$()%.[]*+-?` have special behaviour and muct be escaped with `%`.**

### Preference

The script moves down the list of track preferences until any valid pair of audio and subtitle tracks are found. Once this happens the script immediately sets the subtitle track and terminates. If none of the tracks match then track selection is deferred to mpv.

### Special Strings

There are a number of strings that can be used for the `alang` and `slang` which have special behaviour.
If `alang` is not defined it defaults to `*`.

**alang:**
| String | Action                                  |
|--------|-----------------------------------------|
| *      | matches any language                    |
| no     | matches when no audio track is selected - not included by `*` |
| default| matches audio with the `default` tag    |
| forced | matches audio with the `forced` tag     |

**slang:**
| String  | Action                                        |
|---------|-----------------------------------------------|
| *       | matches the first track that passes the filters|
| no      | disables subs if `alang` matches              |
| default | selects subtitles with the `default` tag      |
| forced  | selects subtitles with the `forced` tag       |

## Commands

The script supports two commands to control subtitle selection.

### `script-message select-subtitles`

This command will force subtitle selection during runtime based on the current audio track.

### `script-message sub-select [arg]`

This command will enable/disable the script. Valid arguments are `enable`, `disable`, and `toggle`. If the script gets enabled then the current subtitle track will be reselected.

## Auto-Switch Mode

The `detect_audio_switches` script-opt allows one to enable Auto-Switch Mode. In this mode the script will automatically reselect the subtitles when the script detects that the audio language has changed.
This setting ignores `--sid=auto`, but when using synchronous mode the script will not change the original `sid` until the first audio switch. This feature still respects `--track-auto-selection`.
This mode can be disabled during runtime wi the `sub-select` script message shown above.

## Audio Selection

This is an experimental option to allow advanced selection of pairs of audio and subtitle
tracks. Controlled by the `select_audio` option.

When this option is enabled the script will go through the list
of preferences as usual, but instead of comparing the sub tracks against the current audio
track it will compare it against all audio tracks. If any audio tracks match the alang
and there are subs that match the slang and filters, then that audio track will be
selected.

If multiple audio tracks match a preference then the track that occurs first in the
track list will be chosen. This option does not break `observe_audio_switches`
but will disable the `force_prediction` and `detect_incorrect_predictions` options.

The `whitelist` and `blacklist` will still only work with subs, but the `condition` filter
can be used to implement audio-specific filtering behaviour.

## Synchronous vs Asynchronous Track Selection

The script has two different ways it can select subtitles, controlled with the `preload` script-opt. The default is to load synchronously during the preload phase, which is before track selection; this allows the script to seamlessly change the subtitles to the desired track without any indication that the tracks were switched manually. This likely has better compatability with other options and scripts.

The downside of this method is that when `--aid` is set to auto the script needs to scan the track-list and predict what track mpv will select. Therefore, in some rare situations, this could result in the wrong audio track prediction, and hence the wrong subtitle being selected. There are several solutions to this problem:

### Use Asynchronous Mode (default no)

Disable the hook by setting `preload=no`. This is the simplest and most efficient solution, however it means that track switching messages will be printed to the console and it may break other scripts that use subtitle information.

### Force Prediction (default no)

Force the predicted track to be correct by setting `aid` to the predicted value. This can be enabled with `force_prediction=yes`.
This method works well, but is not ideal if one wants to utilise a more refined audio track selector, or if mpv's default is more desirable.

### Detect Incorrect Predictions (default yes)

Check the audio track when playback starts and compare with the latest prediction, if the prediction was wrong then the subtitle selection is run again. This can be disabled with `detect_incorrect_predictions=no`. This is the best of both worlds, since 99% of the time the subtitles will load seamlessly, and on the rare occasion that the file has weird track tagging the correct subtitles will be reloaded. However, this method does have the highest computational overhead, if anyone cares about that.

Auto-Select Mode enables this intrinsically.

### Use audio selection mode (default no)

See [Audio Selection](#audio-selection).

## Examples

The [sub_select.conf](/sub_select.conf) file contains all of the options for the script and their defaults. The [sub-select.json](/sub-select.json) file contains an example set of track matches.

If all you want is to always display forced subtitles (if available), but also want to have hidden regular ones selected use the example below.
This allows to use a key shortcut (`v` or `Alt+v` with mpv defaults) to toggle the normally hidden regular subtitles, even if the file has forced subtitles, which are always visible.

```json
[
    {
        "slang": ["forced"],
        "secondary_slang": ["eng?"],
        "sub_visibility": true,
        "secondary_sub_visibility": false
    },
    {
        "slang": ["eng?"],
        "sub_visibility": false
    }
]
```
