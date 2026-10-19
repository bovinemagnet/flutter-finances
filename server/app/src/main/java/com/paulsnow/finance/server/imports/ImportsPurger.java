package com.paulsnow.finance.server.imports;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes import batches and their raw rows of a deleted workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ImportsPurger implements WorkspaceDataPurger {

    private final ImportRepository repository;

    ImportsPurger(ImportRepository repository) {
        this.repository = repository;
    }

    @Override
    public String step() {
        return "imports";
    }

    @Override
    public long purge(UUID workspaceId) {
        return repository.purgeWorkspace(workspaceId);
    }
}
