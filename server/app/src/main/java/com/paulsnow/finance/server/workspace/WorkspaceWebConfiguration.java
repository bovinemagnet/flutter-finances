package com.paulsnow.finance.server.workspace;

import java.util.Arrays;
import java.util.List;

import org.springdoc.core.customizers.OperationCustomizer;
import org.springdoc.core.utils.SpringDocUtils;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.method.support.HandlerMethodArgumentResolver;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import io.swagger.v3.oas.models.media.StringSchema;
import io.swagger.v3.oas.models.parameters.HeaderParameter;

/**
 * Registers the workspace argument resolver and documents the headers it
 * reads in the OpenAPI description.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
class WorkspaceWebConfiguration implements WebMvcConfigurer {

    static {
        SpringDocUtils.getConfig().addRequestWrapperToIgnore(CurrentUser.class, CurrentMember.class,
                CurrentDevice.class);
    }

    private final WorkspaceDirectory directory;

    WorkspaceWebConfiguration(WorkspaceDirectory directory) {
        this.directory = directory;
    }

    @Override
    public void addArgumentResolvers(List<HandlerMethodArgumentResolver> resolvers) {
        resolvers.add(new WorkspaceArgumentResolver(directory));
    }

    @Bean
    OperationCustomizer workspaceHeaders() {
        return (operation, handler) -> {
            List<Class<?>> types = Arrays.stream(handler.getMethodParameters())
                    .<Class<?>>map(p -> p.getParameterType()).toList();
            if (types.contains(CurrentDevice.class)) {
                operation.addParametersItem(header(WorkspaceHeaders.DEVICE, true,
                        "Registered, unrevoked device of the caller; selects the workspace."));
            } else if (types.contains(CurrentMember.class)) {
                operation.addParametersItem(header(WorkspaceHeaders.WORKSPACE, false,
                        "Workspace to act on; defaults to the workspace of X-Device-Id."));
                operation.addParametersItem(header(WorkspaceHeaders.DEVICE, false,
                        "Registered device of the caller, used when X-Workspace-Id is absent."));
            }
            return operation;
        };
    }

    private static HeaderParameter header(String name, boolean required, String description) {
        HeaderParameter parameter = new HeaderParameter();
        parameter.setName(name);
        parameter.setRequired(required);
        parameter.setDescription(description);
        parameter.setSchema(new StringSchema().format("uuid"));
        return parameter;
    }
}
