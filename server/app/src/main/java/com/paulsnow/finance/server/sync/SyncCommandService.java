package com.paulsnow.finance.server.sync;

import java.util.ArrayList;
import java.util.List;

import org.springframework.stereotype.Service;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentDevice;
import com.paulsnow.finance.server.workspace.WorkspaceInfo;

/**
 * Entry point for commands. Device commands come through the API; other
 * modules (such as CSV import) submit server-originated commands through
 * the same path, so they get the same validation, idempotency and change
 * records.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class SyncCommandService {

    private final CommandProcessor processor;
    private final SyncProperties properties;

    SyncCommandService(CommandProcessor processor, SyncProperties properties) {
        this.processor = processor;
        this.properties = properties;
    }

    /**
     * Applies a device's batch; each command commits in its own transaction
     * and results are returned in order.
     *
     * @param device   calling device
     * @param commands commands in outbox order
     * @return one result per command
     */
    public List<CommandResult> submit(CurrentDevice device, List<SyncCommand> commands) {
        if (commands.size() > properties.maxCommandsPerBatch()) {
            throw ApiException.badRequest("TOO_MANY_COMMANDS",
                    "Send at most " + properties.maxCommandsPerBatch() + " commands per request.");
        }
        List<CommandResult> results = new ArrayList<>(commands.size());
        for (SyncCommand command : commands) {
            results.add(processor.process(device.member().workspace(), device.deviceId(),
                    device.member().user().id(), device.member().role(), command));
        }
        return results;
    }

    /**
     * Applies a command originated by the server on a member's behalf. The
     * command's {@code deviceId} is not checked.
     *
     * @param workspace workspace
     * @param command   command with a deterministic {@code commandId} for idempotency
     * @return the result
     */
    public CommandResult submitAsServer(WorkspaceInfo workspace, SyncCommand command) {
        return processor.process(workspace, null, null, null, command);
    }
}
