//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Label: type = u64;
pub const FTy: type = union(enum) {
    ty_variable: Label,
    function: struct {
        from: FTy,
        to: FTy,
    },
    universal: struct {
        label: Label,
        ty: FTy,
    },
    fn replace(self: FTy, label: Label, ty: FTy) FTy {
        switch (self) {
            .ty_variable => |l| {
                if (l == label) return ty else return self;
            },
            else => return self,
        }
    }
};
pub const Term = union(enum) {
    variable: Label,
    abstract: struct {
        name: Label,
        ty: FTy,
        term: Term,
    },
    appliction: struct {
        lhs: Term,
        rhs: Term,
    },
    type_abstraction: struct {
        label: Label,
        term: Term,
    },
    type_application: struct {
        term: Term,
        ty: FTy,
    },

    pub fn recurse(self: Term) [](Term) {
        switch (self) {
            .variable => .{},
            .abstract => |t| .{t.term},
            .application => |t| .{ t.lhs, t.rhs },
            .type_abstraction => |t| .{t.term},
            .type_application => |t| .{t.term},
        }
    }
};

pub const Context = []const (union(enum) {
    term: struct { label: Label, ty: FTy },
    ty: struct { label: Label },
});

pub fn replace(term: Term, target: Label, val: Term) Term {
    switch (term) {
        .variable => val,
        .abstract => |t| {
            return .abstract{ t.name, t.ty, replace(t.term, target, val) };
        },
        .appliction => |t| {
            return .application{ replace(t.lhs, target, val), replace(t.rhs, target, val) };
        },
        .type_abstract => |t| {
            return .type_abstract{ t.ty, replace(t.term, target, val) };
        },
        .type_application => |t| {
            return .type_application{ replace(t.term, target, val), t.ty };
        },
    }
}

pub fn tyReplace(term: Term, target: Label, val: FTy) Term {
    switch (term) {
        .variable => term,
        .abstract => |t| {
            return .abstract{ t.name, t.ty.replace(target, val), tyReplace(t.term, target, val) };
        },
        .appliction => |t| {
            return .application{ tyReplace(t.lhs, target, val), tyReplace(t.rhs, target, val) };
        },
        .type_abstract => |t| {
            return .type_abstract{ t.ty.replace(target, val), tyReplace(t.term, target, val) };
        },
        .type_application => |t| {
            return .type_application{ tyReplace(t.term, target, val), t.ty.replace(target, val) };
        },
    }
}

pub fn reduce(term: Term) Term {
    switch (term) {
        .variable => return term,
        .abstract => return term,
        .appliction => |t| {
            const lhs, const rhs = t;

            if (reduce(lhs) == lhs) {
                if (reduce(rhs) == rhs) {
                    switch (lhs) {
                        .abstract => |left_term| {
                            const name, _, const inner = left_term;
                            return replace(inner, name, rhs);
                        },
                        else => return error.ApplyingNonAbstraction,
                    }
                } else {
                    return reduce(rhs);
                }
            } else {
                return reduce(lhs);
            }
        },
        .type_abstraction => return term,
        .type_application => |t| {
            switch (t.term) {
                .type_abstraction => |ta| {
                    return tyReplace(ta.term, t.label, t.ty);
                },
                else => return error.ApplyingNonTypeAbstraction,
            }
        },
    }
}
