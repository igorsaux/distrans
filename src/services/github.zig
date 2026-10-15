// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const root = @import("../root.zig");

const SCOPE = std.log.scoped(.github);

/// Renders supported GitHub event/action combinations into rich embeds.
/// Unknown events, unsupported actions, or incomplete event data yield `null`.
pub fn transform(
    allocator: std.mem.Allocator,
    event: []const u8,
    body: std.json.Value,
) !?root.types.Embed {
    if (body != .object) {
        return null;
    }

    const object = body.object;

    if (std.mem.eql(u8, event, "commit_comment")) {
        return try transformCommitComment(allocator, object);
    } else if (std.mem.eql(u8, event, "create")) {
        return try transformCreate(allocator, object);
    } else if (std.mem.eql(u8, event, "delete")) {
        return try transformDelete(allocator, object);
    } else if (std.mem.eql(u8, event, "fork")) {
        return try transformFork(allocator, object);
    } else if (std.mem.eql(u8, event, "issue_comment")) {
        return try transformIssueComment(allocator, object);
    } else if (std.mem.eql(u8, event, "issues")) {
        return try transformIssue(allocator, object);
    } else if (std.mem.eql(u8, event, "member")) {
        return try transformMember(allocator, object);
    } else if (std.mem.eql(u8, event, "public")) {
        return try transformPublic(allocator, object);
    } else if (std.mem.eql(u8, event, "pull_request")) {
        return try transformPullRequest(allocator, object);
    } else if (std.mem.eql(u8, event, "pull_request_review")) {
        return try transformPullRequestReview(allocator, object);
    } else if (std.mem.eql(u8, event, "pull_request_review_comment")) {
        return try transformPullRequestReviewComment(allocator, object);
    } else if (std.mem.eql(u8, event, "push")) {
        return try transformPush(allocator, object);
    } else if (std.mem.eql(u8, event, "release")) {
        return try transformRelease(allocator, object);
    } else if (std.mem.eql(u8, event, "watch")) {
        return try transformWatch(allocator, object);
    } else if (std.mem.eql(u8, event, "star")) {
        return try transformStar(allocator, object);
    } else if (std.mem.eql(u8, event, "check_run")) {
        return try transformCheckRun(allocator, object);
    } else if (std.mem.eql(u8, event, "check_suite")) {
        return try transformCheckSuite(allocator, object);
    } else if (std.mem.eql(u8, event, "discussion")) {
        return try transformDiscussion(allocator, object);
    } else if (std.mem.eql(u8, event, "discussion_comment")) {
        return try transformDiscussionComment(allocator, object);
    } else if (std.mem.eql(u8, event, "repository")) {
        return try transformRepository(allocator, object);
    }

    return null;
}

inline fn nested(value: ?std.json.Value) ?std.json.ObjectMap {
    const item = value orelse return null;

    if (item != .object) {
        return null;
    }

    return item.object;
}

inline fn getObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return nested(object.get(key));
}

inline fn getString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;

    if (value != .string) {
        return null;
    }

    return value.string;
}

inline fn getInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;

    if (value != .integer) {
        return null;
    }

    return value.integer;
}

inline fn getBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;

    if (value != .bool) {
        return null;
    }

    return value.bool;
}

inline fn isAction(object: std.json.ObjectMap, expected: []const u8) bool {
    const action = getString(object, "action") orelse return false;

    return std.mem.eql(u8, action, expected);
}

/// Byte offset of the first byte after `codepoints` code points. `s` must be
/// valid UTF-8.
inline fn byteOffset(s: []const u8, codepoints: usize) usize {
    var offset: usize = 0;
    var count: usize = 0;

    while (count < codepoints and offset < s.len) : (count += 1) {
        const length = std.unicode.utf8ByteSequenceLength(s[offset]) catch 1;

        offset += length;
    }

    return offset;
}

/// Message-text sanitization (drops forbidden code points), trims, and clamps
/// to `max_codepoints`; the truncation marker (`...`) counts toward the limit.
inline fn text(allocator: std.mem.Allocator, raw: []const u8, max_codepoints: usize) ![]const u8 {
    const sanitized = root.unicode.sanitizeMessageText(allocator, raw) catch |err| switch (err) {
        error.InvalidUtf8 => return allocator.dupe(u8, ""),
        error.OutOfMemory => return error.OutOfMemory,
    };

    const trimmed = std.mem.trim(u8, sanitized, " \t\r\n");
    const count = std.unicode.utf8CountCodepoints(trimmed) catch {
        return allocator.dupe(u8, "");
    };

    if (count <= max_codepoints) {
        return trimmed;
    }

    if (max_codepoints <= 3) {
        return trimmed[0..byteOffset(trimmed, max_codepoints)];
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);

    writer.writer.writeAll(trimmed[0..byteOffset(trimmed, max_codepoints - 3)]) catch |err| {
        return err;
    };

    writer.writer.writeAll("...") catch |err| {
        return err;
    };

    return writer.written();
}

inline fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, 7)];
}

inline fn formatInt(allocator: std.mem.Allocator, value: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{}", .{value});
}

inline fn userAuthor(allocator: std.mem.Allocator, user: std.json.ObjectMap) !?root.types.Embed.Author {
    const login = getString(user, "login") orelse return null;

    return .{
        .name = try allocator.dupe(u8, login),
        .url = getString(user, "html_url"),
        .icon_url = getString(user, "avatar_url"),
    };
}

inline fn senderAuthor(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed.Author {
    const sender = getObject(object, "sender") orelse return null;

    return try userAuthor(allocator, sender);
}

inline fn titleColor(action: []const u8, opened_color: u24, reopened_color: u24) ?u24 {
    if (std.mem.eql(u8, action, "opened")) {
        return opened_color;
    } else if (std.mem.eql(u8, action, "closed")) {
        return 0x000000;
    } else if (std.mem.eql(u8, action, "reopened")) {
        return reopened_color;
    }

    return null;
}

inline fn transformCommitComment(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "created")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const comment = getObject(object, "comment") orelse return null;
    const commit_id = getString(comment, "commit_id") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    const user = getObject(comment, "user") orelse return null;

    return .{
        .url = getString(comment, "html_url"),
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New comment on commit `{s}`",
            .{ full_name, shortSha(commit_id) },
        ), root.options.api.github.max_title_codepoints),
        .description = if (getString(comment, "body")) |body|
            try text(allocator, body, root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try userAuthor(allocator, user),
    };
}

inline fn transformCreate(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const repository = getObject(object, "repository") orelse return null;
    const ref = getString(object, "ref") orelse return null;
    const ref_type = getString(object, "ref_type") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    const title = if (std.mem.eql(u8, ref_type, "branch"))
        try std.fmt.allocPrint(allocator, "[{s}] New branch created: {s}", .{ full_name, ref })
    else if (std.mem.eql(u8, ref_type, "tag"))
        try std.fmt.allocPrint(allocator, "[{s}] New tag created: {s}", .{ full_name, ref })
    else
        return null;

    return .{
        .title = try text(allocator, title, root.options.api.github.max_title_codepoints),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformDelete(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const repository = getObject(object, "repository") orelse return null;
    const ref = getString(object, "ref") orelse return null;
    const ref_type = getString(object, "ref_type") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    const title = if (std.mem.eql(u8, ref_type, "branch"))
        try std.fmt.allocPrint(allocator, "[{s}] Branch deleted: {s}", .{ full_name, ref })
    else if (std.mem.eql(u8, ref_type, "tag"))
        try std.fmt.allocPrint(allocator, "[{s}] Tag deleted: {s}", .{ full_name, ref })
    else
        return null;

    return .{
        .title = try text(allocator, title, root.options.api.github.max_title_codepoints),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformFork(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const repository = getObject(object, "repository") orelse return null;
    const forkee = getObject(object, "forkee") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const forkee_full_name = getString(forkee, "full_name") orelse return null;

    return .{
        .url = getString(forkee, "html_url"),
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] Fork created: {s}",
            .{ full_name, forkee_full_name },
        ), root.options.api.github.max_title_codepoints),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformIssueComment(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "created")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const issue = getObject(object, "issue") orelse return null;
    const comment = getObject(object, "comment") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(issue, "number") orelse return null;
    const issue_title = getString(issue, "title") orelse return null;
    const user = getObject(comment, "user") orelse return null;

    const kind: []const u8 = if (issue.get("pull_request") != null) "pull request" else "issue";

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New comment on {s} #{d}: {s}",
            .{ full_name, kind, number, issue_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(comment, "html_url"),
        .color = 0xc00a7f,
        .description = if (getString(comment, "body")) |body|
            try text(allocator, body, root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try userAuthor(allocator, user),
    };
}

inline fn transformIssue(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const action = getString(object, "action") orelse return null;
    const repository = getObject(object, "repository") orelse return null;
    const issue = getObject(object, "issue") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(issue, "number") orelse return null;
    const issue_title = getString(issue, "title") orelse return null;

    const color = titleColor(action, 0xeb4841, 0xfcbd1f) orelse return null;

    const verb: []const u8 = if (std.mem.eql(u8, action, "opened"))
        "opened"
    else if (std.mem.eql(u8, action, "closed"))
        "closed"
    else
        "reopened";

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] Issue {s}: #{d} {s}",
            .{ full_name, verb, number, issue_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(issue, "html_url"),
        .color = color,
        .description = if (std.mem.eql(u8, action, "opened"))
            try text(allocator, getString(issue, "body") orelse "", root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformMember(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "added")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const member = getObject(object, "member") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const login = getString(member, "login") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New collaborator added: {s}",
            .{ full_name, login },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(member, "html_url"),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformPublic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const repository = getObject(object, "repository") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] Now open sourced!",
            .{full_name},
        ), root.options.api.github.max_title_codepoints),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformPullRequest(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const action = getString(object, "action") orelse return null;
    const repository = getObject(object, "repository") orelse return null;
    const pull_request = getObject(object, "pull_request") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(pull_request, "number") orelse return null;
    const pr_title = getString(pull_request, "title") orelse return null;

    const color = titleColor(action, 0x098efc, 0xfcbd1f) orelse return null;

    const verb: []const u8 = if (std.mem.eql(u8, action, "opened"))
        "opened"
    else if (std.mem.eql(u8, action, "closed"))
        "closed"
    else
        "reopened";

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] Pull request {s}: #{d} {s}",
            .{ full_name, verb, number, pr_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(pull_request, "html_url"),
        .color = color,
        .description = if (std.mem.eql(u8, action, "opened"))
            try text(allocator, getString(pull_request, "body") orelse "", root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformPullRequestReview(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "submitted")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const pull_request = getObject(object, "pull_request") orelse return null;
    const review = getObject(object, "review") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(pull_request, "number") orelse return null;
    const pr_title = getString(pull_request, "title") orelse return null;
    const user = getObject(review, "user") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] Pull request review submitted: #{d} {s}",
            .{ full_name, number, pr_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(review, "html_url"),
        .color = 0x000000,
        .description = if (getString(review, "body")) |body|
            try text(allocator, body, root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try userAuthor(allocator, user),
    };
}

inline fn transformPullRequestReviewComment(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "created")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const pull_request = getObject(object, "pull_request") orelse return null;
    const comment = getObject(object, "comment") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(pull_request, "number") orelse return null;
    const pr_title = getString(pull_request, "title") orelse return null;
    const user = getObject(comment, "user") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New review comment on pull request #{d}: {s}",
            .{ full_name, number, pr_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(comment, "html_url"),
        .color = 0xc00a7f,
        .description = if (getString(comment, "body")) |body|
            try text(allocator, body, root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try userAuthor(allocator, user),
    };
}

inline fn isHex40(s: []const u8) bool {
    if (s.len != 40) {
        return false;
    }

    for (s) |c| {
        if (!std.ascii.isHex(c)) {
            return false;
        }
    }

    return true;
}

/// Rewrites `This reverts commit <40-hex>.` into a version with the short sha
/// linked to the repository commit URL.
inline fn rewriteReverts(allocator: std.mem.Allocator, message: []const u8, repo_url: []const u8) ![]const u8 {
    const needle = "This reverts commit ";

    var writer: std.Io.Writer.Allocating = .init(allocator);
    var rest = message;

    while (std.mem.indexOf(u8, rest, needle)) |position| {
        try writer.writer.writeAll(rest[0 .. position + needle.len]);

        const after = rest[position + needle.len ..];

        if (after.len >= 41 and isHex40(after[0..40]) and after[40] == '.') {
            const hash = after[0..40];

            try writer.writer.print("[`{s}`]({s}/commit/{s}).", .{ hash[0..7], repo_url, hash });

            rest = after[41..];
        } else {
            rest = after;
        }
    }

    try writer.writer.writeAll(rest);

    return writer.written();
}

inline fn transformPush(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const repository = getObject(object, "repository") orelse return null;
    const ref = getString(object, "ref") orelse return null;
    const repo_name = getString(repository, "name") orelse return null;

    var ref_name = ref;
    var ref_type: []const u8 = "Ref";

    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        ref_name = ref["refs/heads/".len..];
        ref_type = "Branch";
    } else if (std.mem.startsWith(u8, ref, "refs/tags/")) {
        ref_name = ref["refs/tags/".len..];
        ref_type = "Tag";
    }

    const forced = getBool(object, "forced") orelse false;

    if (forced) {
        const head_commit = getObject(object, "head_commit") orelse return null;
        const compare = getString(object, "compare") orelse return null;
        const head_id = getString(head_commit, "id") orelse return null;

        return .{
            .url = compare,
            .title = try text(allocator, try std.fmt.allocPrint(
                allocator,
                "[{s}] {s} {s} was force-pushed to `{s}`",
                .{ repo_name, ref_type, ref_name, shortSha(head_id) },
            ), root.options.api.github.max_push_title_codepoints),
            .color = 0xfcbd1f,
            .description = try std.fmt.allocPrint(allocator, "[Compare changes]({s})", .{compare}),
            .author = try senderAuthor(allocator, object),
        };
    }

    const commits = object.get("commits") orelse return null;

    if (commits != .array or commits.array.items.len == 0) {
        return null;
    }

    const compare = getString(object, "compare") orelse return null;
    const repo_html_url = getString(repository, "html_url") orelse return null;

    var description: std.Io.Writer.Allocating = .init(allocator);
    var first = true;

    for (commits.array.items[0..@min(commits.array.items.len, root.options.api.github.max_commits)]) |commit_value| {
        if (commit_value != .object) {
            continue;
        }

        const commit = commit_value.object;
        const id = getString(commit, "id") orelse continue;
        const url = getString(commit, "url") orelse continue;
        const message = getString(commit, "message") orelse continue;
        const author_name = if (getObject(commit, "author")) |author|
            (getString(author, "name") orelse "")
        else
            "";

        if (!first) {
            try description.writer.writeAll("\n");
        }

        first = false;

        const rewritten = try rewriteReverts(allocator, message, repo_html_url);

        try description.writer.print("[`{s}`]({s}) {s} - {s}", .{ shortSha(id), url, rewritten, author_name });
    }

    return .{
        .url = compare,
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}:{s}] {d} new commit{s}",
            .{
                repo_name,
                ref_name,
                commits.array.items.len,
                if (commits.array.items.len > 1) "s" else "",
            },
        ), root.options.api.github.max_push_title_codepoints),
        .color = 0x7289da,
        .description = try text(allocator, description.written(), root.options.api.github.max_description_codepoints),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformRelease(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "published")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const release = getObject(object, "release") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const tag_name = getString(release, "tag_name") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New release published: {s}",
            .{ full_name, tag_name },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(release, "html_url"),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformWatch(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "started")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New repository watcher",
            .{full_name},
        ), root.options.api.github.max_title_codepoints),
        .url = getString(repository, "html_url"),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn transformStar(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    const action = getString(object, "action") orelse return null;
    const repository = getObject(object, "repository") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    const verb = if (std.mem.eql(u8, action, "created"))
        "New star added"
    else if (std.mem.eql(u8, action, "deleted"))
        "Star removed"
    else
        return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ full_name, verb }), root.options.api.github.max_title_codepoints),
        .url = getString(repository, "html_url"),
        .author = try senderAuthor(allocator, object),
    };
}

inline fn conclusionColor(conclusion: ?[]const u8) ?u24 {
    const value = conclusion orelse return null;

    if (std.mem.eql(u8, value, "success")) {
        return 0x009800;
    }

    return 0xfc2929;
}

inline fn transformCheckRun(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "completed")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const check_run = getObject(object, "check_run") orelse return null;
    const check_suite = getObject(check_run, "check_suite") orelse return null;
    const conclusion = getString(check_suite, "conclusion");

    if (conclusion != null and std.mem.eql(u8, conclusion.?, "skipped")) {
        return null;
    }

    const repo_name = getString(repository, "name") orelse return null;
    const repo_html_url = getString(repository, "html_url") orelse return null;
    const head_sha = getString(check_suite, "head_sha") orelse return null;
    const head_branch = getString(check_suite, "head_branch") orelse return null;
    const name = getString(check_run, "name") orelse return null;

    return .{
        .url = try std.fmt.allocPrint(allocator, "{s}/commit/{s}", .{ repo_html_url, head_sha }),
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] {s} {s} on {s}",
            .{ repo_name, name, conclusion orelse "completed", head_branch },
        ), root.options.api.github.max_push_title_codepoints),
        .color = conclusionColor(conclusion),
    };
}

inline fn transformCheckSuite(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "completed")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const check_suite = getObject(object, "check_suite") orelse return null;
    const app = getObject(check_suite, "app") orelse return null;
    const conclusion = getString(check_suite, "conclusion");

    if (conclusion != null and std.mem.eql(u8, conclusion.?, "skipped")) {
        return null;
    }

    const repo_name = getString(repository, "name") orelse return null;
    const repo_html_url = getString(repository, "html_url") orelse return null;
    const head_sha = getString(check_suite, "head_sha") orelse return null;
    const head_branch = getString(check_suite, "head_branch") orelse return null;
    const app_name = getString(app, "name") orelse return null;

    return .{
        .url = try std.fmt.allocPrint(allocator, "{s}/commit/{s}", .{ repo_html_url, head_sha }),
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] {s} checks {s} on {s}",
            .{ repo_name, app_name, conclusion orelse "completed", head_branch },
        ), root.options.api.github.max_push_title_codepoints),
        .color = conclusionColor(conclusion),
    };
}

inline fn transformDiscussion(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "created")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const discussion = getObject(object, "discussion") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(discussion, "number") orelse return null;
    const discussion_title = getString(discussion, "title") orelse return null;
    const user = getObject(discussion, "user") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New discussion #{d}: {s}",
            .{ full_name, number, discussion_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(discussion, "html_url"),
        .color = 0xe6c2b0,
        .description = if (getString(discussion, "body")) |body|
            try text(allocator, body, root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try userAuthor(allocator, user),
    };
}

inline fn transformDiscussionComment(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "created")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const discussion = getObject(object, "discussion") orelse return null;
    const comment = getObject(object, "comment") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;
    const number = getInt(discussion, "number") orelse return null;
    const discussion_title = getString(discussion, "title") orelse return null;
    const user = getObject(comment, "user") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] New comment on discussion #{d}: {s}",
            .{ full_name, number, discussion_title },
        ), root.options.api.github.max_title_codepoints),
        .url = getString(comment, "html_url"),
        .color = 0xe6c2b0,
        .description = if (getString(comment, "body")) |body|
            try text(allocator, body, root.options.api.github.max_description_codepoints)
        else
            null,
        .author = try userAuthor(allocator, user),
    };
}

inline fn transformRepository(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?root.types.Embed {
    if (!isAction(object, "created")) {
        return null;
    }

    const repository = getObject(object, "repository") orelse return null;
    const full_name = getString(repository, "full_name") orelse return null;

    return .{
        .title = try text(allocator, try std.fmt.allocPrint(
            allocator,
            "[{s}] Repository created",
            .{full_name},
        ), root.options.api.github.max_title_codepoints),
        .url = getString(repository, "html_url"),
        .color = 0x2cbe4e,
        .author = try senderAuthor(allocator, object),
    };
}
