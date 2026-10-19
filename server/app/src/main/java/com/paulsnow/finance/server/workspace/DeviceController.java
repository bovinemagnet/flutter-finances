package com.paulsnow.finance.server.workspace;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * Device registration and revocation (SEC 01, SYNC 06). A revoked device
 * loses cloud access at once; its identifier cannot be registered again.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/devices")
@Tag(name = "Devices")
class DeviceController {

    /** Registers a client-generated device identifier in a workspace. */
    record RegisterDeviceRequest(@NotNull UUID deviceId, @NotNull UUID workspaceId,
            @NotBlank @Size(max = 200) String name, @NotBlank @Size(max = 32) String platform) {
    }

    /** A registered device. */
    record DeviceResponse(UUID deviceId, UUID workspaceId, String name, String platform, Instant registeredAt,
            Instant lastSeenAt, boolean revoked, boolean mine) {
    }

    private final WorkspaceDirectory directory;

    DeviceController(WorkspaceDirectory directory) {
        this.directory = directory;
    }

    @PostMapping
    @Operation(summary = "Register one of the caller's devices; repeating it is harmless")
    ResponseEntity<DeviceResponse> register(CurrentUser user, @Valid @RequestBody RegisterDeviceRequest request) {
        CurrentMember member = directory.requireMember(user, request.workspaceId());
        boolean created = directory.registerDevice(member, request.deviceId(), request.name().strip(),
                request.platform().strip());
        WorkspaceDirectory.DeviceRow device = directory.findDevice(request.deviceId()).orElseThrow();
        return ResponseEntity.status(created ? HttpStatus.CREATED : HttpStatus.OK).body(response(device, user));
    }

    @GetMapping
    @Operation(summary = "List devices in the workspace (owners see every member's devices)")
    List<DeviceResponse> list(CurrentMember member) {
        return directory.devicesOf(member.workspaceId()).stream()
                .filter(d -> member.isOwner() || d.userId().equals(member.user().id()))
                .map(d -> response(d, member.user()))
                .toList();
    }

    @DeleteMapping("/{deviceId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Revoke a device's cloud access")
    void revoke(CurrentUser user, @PathVariable UUID deviceId) {
        WorkspaceDirectory.DeviceRow device = directory.findDevice(deviceId)
                .filter(d -> d.userId().equals(user.id())
                        || directory.roleOf(user, d.workspaceId()).filter("owner"::equals).isPresent())
                .orElseThrow(() -> ApiException.notFound("DEVICE_NOT_FOUND", "Device not found."));
        directory.revokeDevice(device, user.id());
    }

    private static DeviceResponse response(WorkspaceDirectory.DeviceRow device, CurrentUser user) {
        return new DeviceResponse(device.id(), device.workspaceId(), device.name(), device.platform(),
                device.registeredAt(), device.lastSeenAt(), device.revokedAt() != null,
                device.userId().equals(user.id()));
    }
}
