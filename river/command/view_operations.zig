// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2023 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const flags = @import("flags");

const server = &@import("../main.zig").server;

const Direction = @import("../command.zig").Direction;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const Vector = @import("../Vector.zig");

/// Focus either the next or the previous visible view, depending on the enum
/// passed. Does nothing if there are 1 or 0 views in the stack.
pub fn focusView(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "skip-floating", .kind = .boolean },
        .{ .name = "cross-output", .kind = .boolean },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };
    if (result.args.len < 1) return Error.NotEnoughArguments;
    if (result.args.len > 1) return Error.TooManyArguments;

    if (try getTarget(
        seat,
        result.args[0],
        if (result.flags.@"skip-floating") .skip_float else .all,
        result.flags.@"cross-output",
    )) |target| {
        assert(!target.pending.fullscreen);
        seat.focus(target);
        server.root.applyPending();
    }
}

/// Swap the currently focused view with either the view higher or lower in the visible stack
pub fn swap(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    const result = flags.parser([:0]const u8, &.{
        .{ .name = "cross-output", .kind = .boolean },
    }).parse(args[1..]) catch {
        return error.InvalidValue;
    };
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    if (try getTarget(seat, args[1], .skip_float, result.flags.@"cross-output")) |target| {
        assert(!target.pending.float);
        assert(!target.pending.fullscreen);
        seat.focused.view.pending_wm_stack_link.swapWith(&target.pending_wm_stack_link);
        seat.cursor.may_need_warp = true;
        server.root.applyPending();
    }
}

const TargetMode = enum { all, skip_float };
fn getTarget(seat: *Seat, direction_str: []const u8, target_mode: TargetMode, cross_output: bool) !?*View {
    if (seat.focused != .view) return null;
    if (seat.focused.view.pending.fullscreen) return null;
    if (target_mode == .skip_float and seat.focused.view.pending.float) return null;
    const output = seat.focused_output orelse return null;

    // If no currently view is focused, focus the first in the stack.
    if (seat.focused != .view) {
        var it = output.pending.wm_stack.iterator(.forward);
        return it.next();
    }

    // Logical direction, based on the view stack.
    if (std.meta.stringToEnum(Direction, direction_str)) |direction| {
        switch (direction) {
            inline else => |dir| {
                const it_dir = comptime switch (dir) {
                    .next => .forward,
                    .previous => .reverse,
                };
                var it = output.pending.wm_stack.iterator(it_dir);
                while (it.next()) |view| {
                    if (view == seat.focused.view) break;
                } else {
                    unreachable;
                }

                // Return the next view in the stack matching the tags if any.
                while (it.next()) |view| {
                    if (target_mode == .skip_float and view.pending.float) continue;
                    if (output.pending.tags & view.pending.tags != 0) return view;
                }

                // Wrap and return the first view in the stack matching the tags if
                // any is found before completing the loop back to the focused view.
                while (it.next()) |view| {
                    if (view == seat.focused.view) return null;
                    if (target_mode == .skip_float and view.pending.float) continue;
                    if (output.pending.tags & view.pending.tags != 0) return view;
                }

                unreachable;
            },
        }
    }

    // Spatial direction, based on view position.
    if (std.meta.stringToEnum(wlr.OutputLayout.Direction, direction_str)) |direction| {
        var focus_box: wlr.Box = undefined;
        server.root.output_layout.getBox(seat.focused_output.?.wlr_output, &focus_box);
        const focus_position = Vector.positionOfBox(seat.focused.view.current.box).add(Vector.positionOfBox(focus_box));

        var target: ?*View = null;
        var target_distance: usize = std.math.maxInt(usize);

        getClosestViewOnOutput(
            seat,
            direction,
            seat.focused_output.?,
            target_mode,
            focus_position,
            &target,
            &target_distance,
        );
        if (cross_output) {
            if (getOutputRelativeToFocus(seat, direction)) |other_output| {
                getClosestViewOnOutput(
                    seat,
                    direction,
                    other_output,
                    target_mode,
                    focus_position,
                    &target,
                    &target_distance,
                );
            }
        }

        return target;
    }

    return Error.InvalidDirection;
}

fn getOutputRelativeToFocus(seat: *Seat, direction: wlr.OutputLayout.Direction) ?*Output {
    var focus_box: wlr.Box = undefined;
    server.root.output_layout.getBox(seat.focused_output.?.wlr_output, &focus_box);
    if (focus_box.empty()) return null;

    const wlr_output = server.root.output_layout.adjacentOutput(
        direction,
        seat.focused_output.?.wlr_output,
        @floatFromInt(focus_box.x + @divTrunc(focus_box.width, 2)),
        @floatFromInt(focus_box.y + @divTrunc(focus_box.height, 2)),
    ) orelse return null;
    return @as(*Output, @ptrFromInt(wlr_output.data));
}

fn getClosestViewOnOutput(
    seat: *Seat,
    direction: wlr.OutputLayout.Direction,
    candidate_output: *Output,
    target_mode: TargetMode,
    focus_position: Vector,
    current_closest: *?*View,
    current_distance: *usize,
) void {
    var candidate_output_box: wlr.Box = undefined;
    server.root.output_layout.getBox(candidate_output.wlr_output, &candidate_output_box);
    if (candidate_output_box.empty()) return;

    var it = candidate_output.pending.wm_stack.iterator(.forward);
    while (it.next()) |view| {
        if (candidate_output.pending.tags & view.pending.tags == 0) continue;
        if (target_mode == .skip_float and view.pending.float) continue;
        if (view == seat.focused.view) continue;
        const view_position = Vector.positionOfBox(view.current.box).add(Vector.positionOfBox(candidate_output_box));
        const position_diff = focus_position.diff(view_position);

        if ((position_diff.direction() orelse continue) != direction) continue;
        const distance = position_diff.length();
        if (distance < current_distance.*) {
            current_closest.* = view;
            current_distance.* = distance;
        }
    }
}
