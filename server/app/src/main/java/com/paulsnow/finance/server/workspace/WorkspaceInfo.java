package com.paulsnow.finance.server.workspace;

import java.time.ZoneId;
import java.util.UUID;

import com.paulsnow.finance.core.money.CurrencyUnit;

/**
 * A workspace's identity and financial settings.
 *
 * @param id       identifier
 * @param name     display name
 * @param currency the single workspace currency (P0)
 * @param timezone timezone that decides local effective dates
 * @author Paul Snow
 * @since 0.0.0
 */
public record WorkspaceInfo(UUID id, String name, CurrencyUnit currency, ZoneId timezone) {
}
