// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");

const plat = @import("plat");

pub inline fn errno() c_int {
    switch (builtin.os.tag) {
        .macos, .freebsd => return plat.__error().*,
        .linux => return plat.__errno_location().*,
        else => @compileError("Not implemented"),
    }
}
