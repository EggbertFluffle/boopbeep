// Written by Harrison DiAmbrosio
// hdiambrosio@gmail.com
// https://eggbert.xyz

const std = @import("std");
const Trigger = @import("Trigger.zig");
const Utils = @import("Utils.zig");
const ma = @import("c");

pub fn oomPanic() noreturn {
  stderr.print("Out of memory error, exiting with 1", .{}) catch {};
  std.process.exit(1);
}

var stdin_reader: std.Io.File.Reader = undefined;
var stdin_buffer: [512]u8 = undefined;
var stdin: *std.Io.Reader = undefined;

var stderr_writer: std.Io.File.Writer = undefined;
var stderr_buffer: [512]u8 = undefined;
var stderr: *std.Io.Writer = undefined;

const MAX_SOUNDS_DEFAULT: u32 = 15;
const NO_INPUT_SLEEP_TIME_MS: i64 = 10;

pub fn main(init: std.process.Init) void {
    defer oomPanic();

    const allocator = init.gpa;
    const io = init.io;

    var quit: bool = false;
    var mute: bool = false;

    // Initialize readers and writters for stderr and stdin
    stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);    
    stdin = &stdin_reader.interface;

    stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    stderr = &stderr_writer.interface;

    // Create the pseudo random number generator
    var prng = blk: {
        const timestamp = std.Io.Timestamp.now(io, .real);
        break :blk std.Random.DefaultPrng.init(@intCast(timestamp.toMilliseconds()));
    };
    const rand = prng.random();


    // Create the audio engine and it's configuration
    var engine: ma.ma_engine = undefined;
    var engine_config: ma.ma_engine_config = ma.ma_engine_config_init();
    engine_config.channels = 32;

    {
        const result = ma.ma_engine_init(&engine_config, &engine);
        if (result != ma.MA_SUCCESS) {
            stderr.print("Failed to initialize audio engine: {s}\n", .{ Utils.ma_get_error(result) }) catch {};
            std.process.exit(1);
        }
    }

    var sound_map: std.StringHashMap(*Trigger) = std.StringHashMap(*Trigger).init(allocator);

    // Or if a sound is still playing
    while (!quit or is_playing(&sound_map)) {
        quit = false;
        const input = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Parent has hungup
                quit = true;
                break;
            },
            else => {
                stderr.print("stderr read error: {}\n", .{err}) catch {};
                break;
            }
        };

        // Discard the trailing \n
        _ = stdin.discard(.limited(1)) catch {};

        var args = std.mem.tokenizeSequence(u8, input, &.{' '});
        const command = args.next();

        // No command provided
        if(command == null) continue;

        if(std.mem.eql(u8, command.?, "load_sound")) {
            const trigger_name = args.next();
            const file_path = args.next();
            const max_sounds_arg = args.next();
            var max_sounds: u32 = MAX_SOUNDS_DEFAULT;

            // Probably a better way to validate input
            if(trigger_name == null or file_path == null) {
                stderr.print("Incorrect use of \"load_sound\": usage $ load_sound <trigger_name> <file_path>\n", .{}) catch {};
                continue;
            }

            if(max_sounds_arg) |msa| {
                max_sounds = std.fmt.parseInt(u32, msa, 10) catch MAX_SOUNDS_DEFAULT;
            }

            load_sound(trigger_name.?, file_path.?, max_sounds, &sound_map, &engine, allocator);
        } else if (std.mem.eql(u8, command.?, "play_sound")) {
            const trigger_name = args.next();

            if(trigger_name == null) {
                stderr.print("Incorrect use of \"play_sound\": usage $ play_sound <trigger_name>", .{}) catch { };
                continue;
            }

            if(!mute) {
                play_sound(trigger_name.?, &sound_map, &rand);
            }
        } else if (std.mem.eql(u8, command.?, "master_volume")) {
            const vol_arg = args.next();

            if(vol_arg == null) {
                stderr.print("Incorrect use of \"master_volume\": usage $ master_volume <volume 1-100>", .{}) catch { };
                continue;
            }

            stderr.print("vol arg: {s}\n", .{ vol_arg.? }) catch {};
            
            var volume: f32 = @floatFromInt(std.fmt.parseInt(i32, vol_arg.?, 10) catch 100);
            volume = if (volume > 100) 100 else (if (volume < 0) 0 else volume);

            {
                const result = ma.ma_engine_set_volume(&engine, volume / 100);
                if(result != ma.MA_SUCCESS) {
                    stderr.print("Unable to set volume: {s}", .{ Utils.ma_get_error(result) }) catch { };
                    continue;
                }
            }
        } else if (std.mem.eql(u8, command.?, "trigger_volume")) {
            const trigger_name = args.next();
            const vol_arg = args.next();

            if(trigger_name == null or vol_arg == null) {
                stderr.print("Incorrect use of \"trigger_volume\": usage $ sound_volume <trigger_name> <volume 1-100>", .{}) catch { };
                continue;
            }
            
            var volume: f32 = @floatFromInt(std.fmt.parseInt(i32, vol_arg.?, 10) catch 100);
            volume = if (volume > 100) 100 else (if (volume < 0) 0 else volume);

            if(sound_map.get(trigger_name.?)) |trigger| {
                trigger.set_volume(volume / 100);
            }
        } else if (std.mem.eql(u8, command.?, "mute")) {
            mute = true;
        } else if (std.mem.eql(u8, command.?, "unmute")) {
            mute = false;
        } else if (std.mem.eql(u8, command.?, "toggle_mute")) {
            mute = !mute;
        } else if (std.mem.eql(u8, command.?, "quit")) {
            quit = true;
        }

        // IMPORTANT
        // Use this to reduce the performance impact
        // Use this to reduce the performance impact
        // Use this to reduce the performance impact
        // Use this to reduce the performance impact
        // Use this to reduce the performance impact
        // look into better solution though
        // std.time.sleep(1 * std.time.ns_per_s);
    }

    std.process.exit(0);
}

fn load_sound(
    trigger_name: []const u8, 
    file_path: []const u8, 
    max_sounds: u32,
    sound_map: *std.StringHashMap(*Trigger),
    engine: *ma.ma_engine,
    allocator: std.mem.Allocator
) void {
    errdefer oomPanic();

    const sound = sound_map.get(trigger_name) orelse blk: {
        const trigger = Trigger.init(allocator);
        const key = try allocator.dupe(u8, trigger_name);
        try sound_map.put(key, trigger);
        break :blk sound_map.get(key);
    };

    sound.?.load_sound(file_path, max_sounds, engine, stderr, allocator);
}

fn play_sound(
    trigger_name: []const u8,
    sound_map: *std.StringHashMap(*Trigger),
    rand: *const std.Random
) void {
    const trigger = sound_map.get(trigger_name);
    if(trigger != null) {
        trigger.?.play_sound(rand, stderr);
    }
}

fn is_playing(sound_map: *std.StringHashMap(*Trigger)) bool {
    var it = sound_map.iterator();
    
    return while (it.next()) |trigger| {
        if (trigger.value_ptr.*.is_playing()) break true;
    } else false;
}
