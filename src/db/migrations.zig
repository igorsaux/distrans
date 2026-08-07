// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const pq = @import("pq");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.db);

const MIGRATIONS_SQL: [:0]const u8 = @embedFile("../migrations_init.sql");

/// Defaults derived from the code, unconditionally re-applied on every start.
const COLUMN_DEFAULTS = [_]struct {
    table: []const u8,
    column: []const u8,
    value: []const u8,
}{
    .{
        .table = "app.roles",
        .column = "permissions",
        .value = root.types.Permissions.defaultEveryoneSqlDefault,
    },
};

pub fn applyMigrations(
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    var conn = try root.db.Connection.init();
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    {
        const res, const err = conn.execExpect(MIGRATIONS_SQL, pq.PGRES_COMMAND_OK);
        defer if (res) |r| r.deinit();

        if (err != null) {
            SCOPE.err("failed to initialize migrations scheme: {s}", .{err.?});

            return error.PGError;
        }
    }

    const dir = try std.Io.Dir.cwd().openDir(io, "migrations", .{
        .iterate = true,
    });
    defer dir.close(io);

    var dir_it = dir.iterate();

    const MigrationEntry = struct {
        path: []u8,
        version: usize,
        name: []const u8,
    };

    var entries: std.ArrayList(MigrationEntry) = .empty;

    while (try dir_it.next(io)) |fs_entry| {
        if (fs_entry.kind != .file) {
            continue;
        }

        const delim = std.mem.findScalar(u8, fs_entry.name, '_') orelse {
            SCOPE.warn("bad migration file name: '{s}'", .{fs_entry.name});

            continue;
        };

        const version = std.fmt.parseInt(usize, fs_entry.name[0..delim], 10) catch |err| {
            SCOPE.warn("failed to parse version of file '{s}': {t}", .{ fs_entry.name, err });

            continue;
        };

        const path = try arena.allocator().dupe(u8, fs_entry.name);
        const name = std.fs.path.stem(path[(delim + 1)..]);

        const entry: MigrationEntry = .{
            .path = path,
            .version = version,
            .name = name,
        };

        try entries.append(arena.allocator(), entry);
    }

    const sortFn = struct {
        fn sort(ctx: void, lhs: MigrationEntry, rhs: MigrationEntry) bool {
            _ = ctx;

            return lhs.version < rhs.version;
        }
    }.sort;

    std.mem.sort(MigrationEntry, entries.items, {}, sortFn);

    var last_applied: ?usize = null;

    {
        const res, const err = conn.execExpect(
            \\SELECT h.version
            \\FROM _migration.history as h
            \\ORDER BY h.version DESC
            \\LIMIT 1;
        , pq.PGRES_TUPLES_OK);
        defer if (res) |r| r.deinit();

        if (err != null) {
            SCOPE.err("failed to get the last applied migration: {s}", .{err.?});

            return error.PGError;
        }

        std.debug.assert(res.?.nfields() == 1);

        if (res.?.ntuples() != 0) {
            const version_len = res.?.getLength(0, 0);
            const version_raw = res.?.getValue(0, 0)[0..version_len];

            last_applied = std.fmt.parseInt(usize, version_raw, 10) catch |e| {
                SCOPE.err("failed to parse the version field: {t}", .{e});

                return e;
            };
        }
    }

    if (last_applied != null) {
        SCOPE.debug("last applied migration: {d}", .{last_applied.?});
    }

    for (entries.items) |*entry| {
        if (last_applied != null and entry.version <= last_applied.?) {
            continue;
        }

        const content = dir.readFileAllocOptions(io, entry.path, arena.allocator(), .unlimited, .@"1", 0) catch |err| {
            SCOPE.err("failed to read migration file '{s}': {t}", .{ entry.path, err });

            return err;
        };
        defer arena.allocator().free(content);

        SCOPE.info("applying migration '{s}'", .{entry.path});

        {
            const res, const err = conn.execExpect("BEGIN", pq.PGRES_COMMAND_OK);
            defer if (res) |r| r.deinit();

            if (err != null) {
                SCOPE.err("failed to begin migration: {s}", .{err.?});

                return error.PGError;
            }
        }

        {
            const res, const err = conn.execExpect(content, pq.PGRES_COMMAND_OK);
            defer if (res) |r| r.deinit();

            if (err != null) {
                SCOPE.err("failed to execute migration: {s}", .{err.?});
                conn.execDiscard("ROLLBACK");

                return error.PGError;
            }
        }

        {
            var params: [2][*:0]const u8 = undefined;

            params[0] = try std.fmt.allocPrintSentinel(arena.allocator(), "{}", .{entry.version}, 0);
            params[1] = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}", .{entry.name}, 0);

            const res, const err = conn.execParamsExpect(
                \\INSERT INTO _migration.history (version, name)
                \\VALUES ($1, $2);
            , &params, pq.PGRES_COMMAND_OK);

            defer if (res) |r| r.deinit();

            if (err != null) {
                SCOPE.err("failed to add migration: {s}", .{err.?});
                conn.execDiscard("ROLLBACK");

                return error.PGError;
            }
        }

        {
            const res, const err = conn.execExpect("COMMIT", pq.PGRES_COMMAND_OK);
            defer if (res) |r| r.deinit();

            if (err != null) {
                SCOPE.err("failed to commit migration: {s}", .{err.?});
                conn.execDiscard("ROLLBACK");

                return error.PGError;
            }
        }
    }

    inline for (COLUMN_DEFAULTS) |column_default| {
        const query = try std.fmt.allocPrintSentinel(arena.allocator(),
            \\ALTER TABLE {s} ALTER COLUMN {s} SET DEFAULT '{s}'::bytea;
        , .{ column_default.table, column_default.column, column_default.value }, 0);
        defer arena.allocator().free(query);

        const res, const err = conn.execExpect(query, pq.PGRES_COMMAND_OK);
        defer if (res) |r| r.deinit();

        if (err != null) {
            SCOPE.err("failed to set default of '{s}.{s}': {s}", .{ column_default.table, column_default.column, err.? });

            return error.PGError;
        }

        SCOPE.debug("set default of '{s}.{s}' to '{s}'", .{ column_default.table, column_default.column, column_default.value });
    }
}
