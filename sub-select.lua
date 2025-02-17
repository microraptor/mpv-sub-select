--[[
    mpv-sub-select

    This script allows you to configure advanced subtitle track selection based on
    the current audio track and the names and language of the subtitle tracks.

    https://github.com/CogentRedTester/mpv-sub-select
]]--

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local opt = require 'mp.options'

local o = {
    --forcibly enable the script regardless of the sid option
    force_enable = false,

    --selects subtitles synchronously during the preloaded hook, which has better
    --compatability with other scripts and options
    --this requires that the script predict what the default audio track will be,
    --so this can be wrong on some rare occasions
    --disabling this will switch the subtitle track after playback starts
    preload = true,

    --experimental audio track selection based on the preferences.
    --this overrides force_prection and detect_incorrect_predictions.
    select_audio = false,

    --remove any potential prediction failures by forcibly selecting whichever
    --audio track was predicted
    force_prediction = false,

    --detect when a prediction is wrong and re-check the subtitles
    --this is automatically disabled if `force_prediction` is enabled
    detect_incorrect_predictions = true,

    --observe audio switches and reselect the subtitles when alang changes
    observe_audio_switches = false,

    --only select forced subtitles if they are explicitly included in slang
    explicit_forced_subs = false,

    --the folder that contains the 'sub-select.json' file
    config = "~~/script-opts"
}

opt.read_options(o, "sub_select")

local file = assert(io.open(mp.command_native({"expand-path", o.config}) .. "/sub-select.json"))
local json = file:read("*all")
file:close()
local prefs = utils.parse_json(json)

if prefs == nil then
    error("Invalid JSON format in sub-select.json.")
end

local ENABLED = o.force_enable or mp.get_property("options/sid", "auto") == "auto"
local latest_audio = {}
local alang_priority = mp.get_property_native("alang", {})
local audio_tracks = {}
local sub_tracks = {}

--returns a table that stores the given table t as the __index in its metatable
--creates a prototypally inherited table
local function redirect_table(t, new)
    return setmetatable(new or {}, { __index = t })
end

--evaluates and runs the given string in both Lua 5.1 and 5.2
--the name argument is used for error reporting
--provides the mpv modules and the fb module to the string
local function evaluate_string(str, env)
    env = redirect_table(_G, env)
    env.mp = redirect_table(mp)
    env.msg = redirect_table(msg)
    env.utils = redirect_table(utils)

    local chunk, err
    if setfenv then
        chunk, err = loadstring(str)
        if chunk then setfenv(chunk, env) end
    else
        chunk, err = load(str, nil, 't', env)
    end
    if not chunk then
        msg.warn('failed to load string:', str)
        msg.error(err)
        chunk = function() return nil end
    end

    local success, boolean = pcall(chunk)
    if not success then msg.error(boolean) end
    return boolean
end

--anticipates the default audio track
--returns the node for the predicted track
--this whole function can be skipped if the user decides to load the subtitles asynchronously instead,
--or if `--aid` is not set to `auto`
local function predict_audio()
    --if the option is not set to auto then it is easy
    local opt = mp.get_property("options/aid", "auto")
    if opt == "no" then return {}
    elseif opt ~= "auto" then return audio_tracks[tonumber(opt)] end

    local num_tracks = #audio_tracks
    if num_tracks == 1 then return audio_tracks[1]
    elseif num_tracks == 0 then return {} end

    local highest_priority = nil
    local priority_str = ""
    local num_prefs = #alang_priority

    --loop through the track list for any audio tracks
    for i = 1, num_tracks do
        local track = audio_tracks[i]
        if track.forced then return track end

        --loop through the alang list to check if it has a preference
        local pref = 0
        for j = 1, num_prefs do
            if track.lang == alang_priority[j] then

                --a lower number j has higher priority, so flip the numbers around so the lowest j has highest preference
                pref = num_prefs - j
                break
            end
        end

        --format the important preferences so that we can easily use a lexicographical comparison to find the default
        local formatted_str = string.format("%03d-%d-%02d", pref, track.default and 1 or 0, num_tracks - track.id)
        msg.trace("formatted track info: " .. formatted_str)

        if formatted_str > priority_str then
            priority_str = formatted_str
            highest_priority = track
        end
    end

    msg.verbose("predicted audio track is "..tostring(highest_priority.id))
    return highest_priority
end

--sets the subtitle track to the given sid
--this is a function to prepare for some upcoming functionality, but I've forgotten what that is
local function set_track(type, id)
    msg.verbose("setting", type, "to", id)
    if mp.get_property_number(type) == id then return end
    mp.set_property(type, id)
end

--checks if the given audio matches the given track preference
local function is_valid_audio(audio, pref)
    local alangs = type(pref.alang) == "string" and {pref.alang} or pref.alang

    --if alang is not set, allow any audio track
    if not alangs then return true end

    for _,lang in ipairs(alangs) do
        msg.debug("Checking for valid audio:", lang)

        if (not audio or not next(audio)) and lang == "no" then
            return true
        elseif audio then
            if lang == '*' then
                return true
            elseif lang == "forced" then
                if audio.forced then return true end
            elseif lang == "default" then
                if audio.default then return true end
            else
                if audio.lang and audio.lang:find(lang) then return true end
            end
        end
    end
    return false
end

--checks if the given sub matches the given track preference
local function is_valid_sub(sub, slang, whitelist, blacklist)
    msg.trace("checking sub", slang, "against track", utils.to_string(sub))

    -- Do not try to un-nest these if statements, it will break detection of default and forced tracks.
    -- I've already had to un-nest these statements twice due to this mistake, don't let it happen again.
    if slang == "default" then
        if not sub.default then return false end
    elseif slang == "forced" then
        if not sub.forced then return false end
    else
        if sub.forced and o.explicit_forced_subs then return false end
        if not sub.lang:find(slang) and slang ~= "*" then return false end
    end

    local title = sub.title

    -- if the whitelist is not set then we don't need to find anything
    local passes_whitelist = not whitelist
    local passes_blacklist = true

    -- whitelist/blacklist handling
    if whitelist and title then
        for _,word in ipairs(whitelist) do
            if title:lower():find(word) then passes_whitelist = true end
        end
    end

    if blacklist and title then
        for _,word in ipairs(blacklist) do
            if title:lower():find(word) then passes_blacklist = false end
        end
    end

    msg.trace(string.format("%s %s whitelist: %s | %s blacklist: %s",
        title,
        passes_whitelist and "passed" or "failed", utils.to_string(whitelist),
        passes_blacklist and "passed" or "failed", utils.to_string(blacklist)
    ))
    return passes_whitelist and passes_blacklist
end

--scans the track list and selects audio and subtitle tracks which match the track preferences
--if an audio track is provided to the function it will assume this track is the only audio
local function find_valid_tracks(manual_audio)
    local audio_track_list = manual_audio and {manual_audio} or {unpack(audio_tracks)}

    --adds a false entry to the list to represent no audio being selected
    if (not manual_audio) then table.insert(audio_track_list, false) end

    if manual_audio then msg.debug("select subtitle for", utils.to_string(manual_audio))
    else msg.debug('selecting audio and subtitles') end

    --searching the selection presets for one that applies to this track
    for _,pref in ipairs(prefs) do
        msg.trace("checking pref:", utils.to_string(pref))

        for _, audio_track in ipairs(audio_track_list) do
            if is_valid_audio(audio_track, pref) then
                -- the audio track can be false
                local aid = audio_track and audio_track.id or 0

                --checks if any of the subtitle tracks match the preset for the current audio
                local slangs = type(pref.slang) == "string" and {pref.slang} or pref.slang
                msg.verbose("valid audio preference found:", utils.to_string(pref.alang))

                for _, slang in ipairs(slangs) do
                    msg.debug("checking for valid sub:", slang)
                    local sid = nil
                    local prim_sub_track = nil

                    --special handling when we want to disable subtitles
                    if slang == "no" and (not pref.condition or (evaluate_string(
                        'return '..pref.condition, { audio = audio_track or nil }
                    ) == true)) then
                        sid = 0
                    else
                        --search for matching sub
                        for _,sub_track in ipairs(sub_tracks) do
                            if is_valid_sub(sub_track, slang, pref.whitelist, pref.blacklist)
                                and (not pref.condition or (evaluate_string('return '..pref.condition, {
                                    audio = audio_track or nil, sub = sub_track
                                }) == true))
                            then
                                sid = sub_track.id
                                prim_sub_track = sub_track
                                break
                            end
                        end
                    end
                    
                    --if matching sub was found
                    if sid or sid == 0 then
                        
                        --search for matching secondary sub
                        local sec_sid = nil
                        local sec_sub_track = nil
                        if pref.secondary_slang then
                            local sec_slangs = type(pref.secondary_slang) ==
                                "string" and {pref.secondary_slang} or pref.secondary_slang
                            for _, sec_slang in ipairs(sec_slangs) do
                                if sec_slang == "no" then
                                    sec_sid = 0
                                    break
                                elseif sec_slang then
                                    --iterate through sub tracks to test against secondary slang
                                    msg.debug("checking for secondary sub:", sec_slang)
                                    for _,sub_track in ipairs(sub_tracks) do
                                        if is_valid_sub(
                                            sub_track,
                                            sec_slang,
                                            pref.secondary_whitelist,
                                            pref.secondary_blacklist
                                        ) and sub_track.id ~= sid
                                        and (not pref.secondary_condition or (
                                            evaluate_string('return '..pref.secondary_condition, {
                                                audio = audio_track or nil,
                                                sub = prim_sub_track,
                                                secondary_sub = sub_track
                                            }) == true
                                        ))
                                        then
                                            sec_sid = sub_track.id
                                            sec_sub_track = sub_track
                                            break
                                        end
                                    end
                                --if matching secondary sub was found
                                if sec_sid then break end
                                end
                            end
                        end

                        --print and return selected tracks
                        msg.info("tracks selected:")
                        msg.info("audio =>", not aid and "not set" or (aid == 0 and "disabled" or (
                            audio_track and audio_track.lang or "unknown"
                        )), ";", audio_track and audio_track.title or "")
                        msg.info("subtitles =>", not sid and "not set" or (sid == 0 and "disabled" or (
                            prim_sub_track and prim_sub_track.lang or "unknown"
                        )), ";", prim_sub_track and prim_sub_track.title or "")
                        msg.info("secondary subtitles =>", not sec_sid and "not set" or (sec_sid == 0 and "disabled" or (
                            sec_sub_track and sec_sub_track.lang or "unknown"
                        )), ";", sec_sub_track and sec_sub_track.title or "")
                        return aid, sid, sec_sid, pref.sub_visibility, pref.secondary_sub_visibility
                    end
                end
            end
        end
    end
    msg.info("no valid subtitles matching the preferences found")
    return nil, nil, nil, nil, nil
end


--returns the audio node for the currently playing audio track
local function find_current_audio()
    local aid = mp.get_property_number("aid", 0)
    return audio_tracks[aid] or {}
end

--extract the language code from an audio track node and pass it to select_subtitles
local function select_tracks(audio)
    -- if the audio track has no fields we assume that there is no actual track selected
    local aid, sid, sec_sid, sub_visibility, sec_sub_visibility = find_valid_tracks(audio)
    if sid then
        set_track('sid', sid == 0 and 'no' or sid)
    end
    if sec_sid then
        set_track('secondary-sid', sec_sid == 0 and 'no' or sec_sid)
    end
    if aid and o.select_audio then
        set_track('aid', aid == 0 and 'no' or aid)
    end
    if sub_visibility ~= nil then
        msg.verbose("setting sub-visibility to", tostring(sub_visibility))
        if not mp.get_property_bool("sub-visibility") == sub_visibility then
            mp.set_property_bool("sub-visibility", sub_visibility)
        end
    end
    if sec_sub_visibility ~= nil then
        msg.verbose("setting secondary-sub-visibility to", tostring(sec_sub_visibility))
        if not mp.get_property_bool("secondary-sub-visibility") == sec_sub_visibility then
            mp.set_property_bool("secondary-sub-visibility", sec_sub_visibility)
        end
    end

    latest_audio = find_current_audio()
end

--select subtitles asynchronously after playback start
local function async_load()
    select_tracks(not o.select_audio and find_current_audio() or nil)
end

--select subtitles synchronously during the on_preloaded hook
local function preload()
    if o.select_audio then return select_tracks() end

    local audio = predict_audio()
    if o.force_prediction and next(audio) then set_track("aid", audio.id) end
    select_tracks(audio)
end

local track_auto_selection = true
mp.observe_property("track-auto-selection", "bool", function(_,b) track_auto_selection = b end)

local function continue_script()
    if #sub_tracks < 1 then return false end
    if not ENABLED then return false end
    if not track_auto_selection then return false end
    return true
end

--reselect the subtitles if the audio is different from what was last used
local function reselect_subtitles()
    if not continue_script() then return end
    local aid = mp.get_property_number("aid", 0)
    if latest_audio.id ~= aid then
        local audio = audio_tracks[aid] or {}
        if audio.lang ~= latest_audio.lang then
            msg.info("detected audio change - reselecting subtitles")
            select_tracks(audio)
        end
    end
end

--setups the audio and subtitle track lists to use for the rest of the script
local function read_track_list()
    local track_list = mp.get_property_native("track-list", {})
    audio_tracks = {}
    sub_tracks = {}
    for _,track in ipairs(track_list) do
        if not track.lang then track.lang = "und" end

        if track.type == "audio" then
            table.insert(audio_tracks, track)
        elseif track.type == "sub" then
            table.insert(sub_tracks, track)
        end
    end
end

--setup the audio and subtitle track lists when a new file is loaded
mp.add_hook('on_preloaded', 25, read_track_list)

--events for file loading
if o.preload then
    mp.add_hook('on_preloaded', 30, function()
        if not continue_script() then return end
        preload()
    end)

    --double check if the predicted subtitle was correct
    if o.detect_incorrect_predictions and not o.select_audio and not o.force_prediction and not o.observe_audio_switches then
        mp.register_event("file-loaded", reselect_subtitles)
    end
else
    mp.register_event("file-loaded", function()
        if not continue_script() then return end
        async_load()
    end)
end

--reselect subs when changing audio tracks
if o.observe_audio_switches then
    mp.observe_property("aid", "string", function(_,aid)
        if aid ~= "auto" then reselect_subtitles() end
    end)
end

mp.observe_property('track-list/count', 'number', read_track_list)

--force subtitle selection during playback
mp.register_script_message("select-subtitles", async_load)

--toggle sub-select during playback
mp.register_script_message("sub-select", function(arg)
    if arg == "toggle" then ENABLED = not ENABLED
    elseif arg == "enable" then ENABLED = true
    elseif arg == "disable" then ENABLED = false end
    local str = "sub-select: ".. (ENABLED and "enabled" or "disabled")
    mp.osd_message(str)

    if not continue_script() then return end
    async_load()
end)
