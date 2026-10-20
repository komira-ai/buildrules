"""constraint_setting / constraint_value / platform, for the mini-prelude experiment only
(a prelude replacement must supply the configuration rules the bundled prelude supplies)."""

def _setting_impl(ctx):
    return [DefaultInfo(), ConstraintSettingInfo(label = ctx.label.raw_target())]

constraint_setting = rule(impl = _setting_impl, attrs = {})

def _value_impl(ctx):
    v = ConstraintValueInfo(setting = ctx.attrs.constraint_setting[ConstraintSettingInfo], label = ctx.label.raw_target())
    return [DefaultInfo(), v, ConfigurationInfo(constraints = {v.setting.label: v}, values = {})]

constraint_value = rule(
    impl = _value_impl,
    attrs = {"constraint_setting": attrs.dep(providers = [ConstraintSettingInfo])},
)

def _platform_impl(ctx):
    constraints = {}
    values = {}
    for dep in ctx.attrs.constraint_values:
        constraints.update(dep[ConfigurationInfo].constraints)
        values.update(dep[ConfigurationInfo].values)
    cfg = ConfigurationInfo(constraints = constraints, values = values)
    return [DefaultInfo(), PlatformInfo(label = str(ctx.label.raw_target()), configuration = cfg)]

platform = rule(
    impl = _platform_impl,
    attrs = {"constraint_values": attrs.list(attrs.dep(providers = [ConfigurationInfo]), default = [])},
)
