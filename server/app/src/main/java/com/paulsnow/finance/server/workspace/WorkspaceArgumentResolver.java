package com.paulsnow.finance.server.workspace;

import java.util.UUID;

import org.springframework.core.MethodParameter;
import org.springframework.web.bind.support.WebDataBinderFactory;
import org.springframework.web.context.request.NativeWebRequest;
import org.springframework.web.method.support.HandlerMethodArgumentResolver;
import org.springframework.web.method.support.ModelAndViewContainer;

import com.paulsnow.finance.server.common.ApiException;

/**
 * Supplies {@link CurrentUser}, {@link CurrentMember} and
 * {@link CurrentDevice} controller parameters, so authorisation is resolved
 * before any handler code runs.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class WorkspaceArgumentResolver implements HandlerMethodArgumentResolver {

    private final WorkspaceDirectory directory;

    WorkspaceArgumentResolver(WorkspaceDirectory directory) {
        this.directory = directory;
    }

    @Override
    public boolean supportsParameter(MethodParameter parameter) {
        Class<?> type = parameter.getParameterType();
        return type == CurrentUser.class || type == CurrentMember.class || type == CurrentDevice.class;
    }

    @Override
    public Object resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest request, WebDataBinderFactory binderFactory) {
        CurrentUser user = directory.currentUser();
        Class<?> type = parameter.getParameterType();
        if (type == CurrentUser.class) {
            return user;
        }
        UUID workspaceHeader = uuidHeader(request, WorkspaceHeaders.WORKSPACE);
        UUID deviceHeader = uuidHeader(request, WorkspaceHeaders.DEVICE);
        if (type == CurrentDevice.class) {
            if (deviceHeader == null) {
                throw ApiException.badRequest("DEVICE_REQUIRED", "Send the X-Device-Id of a registered device.");
            }
            return directory.requireDevice(user, deviceHeader, workspaceHeader);
        }
        UUID workspaceId = workspaceHeader;
        if (workspaceId == null && deviceHeader != null) {
            workspaceId = directory.workspaceOfDevice(user, deviceHeader).orElse(null);
        }
        if (workspaceId == null) {
            throw ApiException.badRequest("WORKSPACE_REQUIRED", "Send X-Workspace-Id or a registered X-Device-Id.");
        }
        return directory.requireMember(user, workspaceId);
    }

    private static UUID uuidHeader(NativeWebRequest request, String name) {
        String value = request.getHeader(name);
        if (value == null || value.isBlank()) {
            return null;
        }
        try {
            return UUID.fromString(value.strip());
        } catch (IllegalArgumentException e) {
            throw ApiException.badRequest("INVALID_REQUEST", name + " must be a UUID.");
        }
    }
}
