package com.paulsnow.finance.server.sync;

import java.util.List;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentDevice;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * The sync endpoints of {@code spec/sync/protocol.md}. Every call needs a
 * registered, unrevoked device of the caller ({@code X-Device-Id}).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/sync")
@Tag(name = "Sync")
class SyncController {

    /** A batch of at most 500 commands. */
    record CommandBatch(List<SyncCommand> commands) {
    }

    /** Results in the same order as the commands. */
    record CommandResults(List<CommandResult> results) {
    }

    private final SyncCommandService commands;
    private final ChangeFeedService feed;

    SyncController(SyncCommandService commands, ChangeFeedService feed) {
        this.commands = commands;
        this.feed = feed;
    }

    @PostMapping("/commands")
    @Operation(summary = "Submit commands; each commits atomically with its idempotency and change records")
    CommandResults submit(CurrentDevice device, @RequestBody CommandBatch batch) {
        if (batch == null || batch.commands() == null) {
            throw ApiException.badRequest("INVALID_REQUEST", "Send {\"commands\": [...]}.");
        }
        return new CommandResults(commands.submit(device, batch.commands()));
    }

    @GetMapping("/changes")
    @Operation(summary = "Pull changes after an opaque cursor; 410 CURSOR_EXPIRED means rebuild from a snapshot")
    ChangeFeedService.ChangePage changes(CurrentDevice device,
            @RequestParam(required = false, defaultValue = "") String cursor,
            @RequestParam(required = false) Integer limit) {
        return feed.changes(device, cursor, limit);
    }

    @GetMapping("/snapshot")
    @Operation(summary = "Page through every live entity, ordered by entity key")
    ChangeFeedService.SnapshotPage snapshot(CurrentDevice device,
            @RequestParam(required = false, defaultValue = "") String after,
            @RequestParam(required = false) Integer limit) {
        return feed.snapshot(device, after, limit);
    }
}
