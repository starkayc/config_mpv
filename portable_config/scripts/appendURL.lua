-- appendurl - Tsubajashi (fixed)
-- Appends clipboard URL to mpv playlist with Ctrl+v

local platform = nil --set to 'linux', 'windows' or 'macos' to override automatic assign

if not platform then
  local o = {}
  if mp.get_property_native('options/vo-mmcss-profile', o) ~= o then
    platform = 'windows'
  elseif mp.get_property_native('options/input-app-events', o) ~= o then
    platform = 'macos'
  else
    platform = 'linux'
  end
end

local utils = require 'mp.utils'
local msg = require 'mp.msg'

--main function
function append(primaryselect)
  local clipboard = get_clipboard(primaryselect or false)
  if clipboard and clipboard ~= '' then
    mp.commandv('loadfile', clipboard, 'append-play')
    mp.osd_message('URL appended: ' .. clipboard)
    msg.info('URL appended: ' .. clipboard)
  else
    mp.osd_message('No URL found in clipboard')
    msg.warn('No URL in clipboard')
  end
end

--handles the subprocess response table and return clipboard if it was a success
function handleres(res, args, primary)
  if not res.error and res.status == 0 and res.stdout and res.stdout ~= '' then
    -- strip trailing whitespace/newlines (mpv's loadfile fails on these)
    return res.stdout:gsub('%s+$', '')
  else
    --if clipboard failed try primary selection
    if platform == 'linux' and not primary then
      append(true)
      return nil
    end
    msg.error('There was an error getting ' .. platform .. ' clipboard: ')
    msg.error('  Status: ' .. (res.status or ''))
    msg.error('  Error: ' .. (res.error or ''))
    msg.error('  stdout: ' .. (res.stdout or ''))
    return nil
  end
end

function get_clipboard(primary)
  if platform == 'linux' then
    local args = { 'xclip', '-selection', primary and 'primary' or 'clipboard', '-out' }
    return handleres(utils.subprocess({ args = args, playback_only = false }), args, primary)
  elseif platform == 'windows' then
    -- playback_only=false is CRITICAL: the default (true) kills the
    -- subprocess immediately when no file is playing.
    -- -sta forces STA threading mode (required for clipboard access).
    local args = {
      'powershell', '-sta', '-NoProfile', '-Command',
      [[try { $c = Get-Clipboard -Raw -ErrorAction Stop } catch {}; if (-not $c) { try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; $c = [System.Windows.Forms.Clipboard]::GetText() } catch {} }; if ($c) { $c -replace '\r?\n|\r','' } else { '' }]]
    }
    return handleres(utils.subprocess({ args = args, playback_only = false }), args)
  elseif platform == 'macos' then
    local args = { 'pbpaste' }
    return handleres(utils.subprocess({ args = args, playback_only = false }), args)
  end
  return nil
end

mp.add_key_binding('Ctrl+v', 'appendURL', append)