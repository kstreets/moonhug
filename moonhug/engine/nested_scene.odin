package engine

import "core:encoding/json"
import "core:strings"
import "core:reflect"

Override :: struct {
    target:        Local_ID,
    property_path: string,
    value:         json.Value,
}

Breadcrumb :: struct {
    local_id:           Local_ID,  // referrer will use this local_id for resolving
    scene_source:       PPtr,      // contains asset guid and local_id inside it
    scene_instance:     Local_ID,  // local_id of prefab instance in this file
}

pptr_guid_is_empty :: proc(g: Asset_GUID) -> bool {
    return g == Asset_GUID{}
}

pptr_equals :: proc(a, b: PPtr) -> bool {
	return a.local_id == b.local_id && a.guid == b.guid
}

// Reads `local_id` directly off `obj`, falling back to `obj.base.local_id` when
// the row stores its identity under a wrapper. Used by overrides apply/diff and
// any other code walking serialized scene-section arrays.
@(private = "file")
_json_local_id_of :: proc(obj: json.Object) -> (Local_ID, bool) {
	from_value :: proc(v: json.Value) -> (Local_ID, bool) {
		if f, ok := v.(json.Float);   ok do return Local_ID(f), true
		if i, ok := v.(json.Integer); ok do return Local_ID(i), true
		return 0, false
	}
	if v, ok := obj["local_id"]; ok do return from_value(v)
	if bv, ok := obj["base"]; ok {
		if bo, ok2 := bv.(json.Object); ok2 {
			if v, ok3 := bo["local_id"]; ok3 do return from_value(v)
		}
	}
	return 0, false
}

scene_file_remap_merge_metadata :: proc(sf: ^SceneFile, s: ^Scene) {
	if s == nil do return
	used := make(map[Local_ID]bool, context.temp_allocator)
	for lid, _ in s.local_ids.forward {
		used[lid] = true
	}
	for lid, _ in s.breadcrumb_data {
		used[lid] = true
	}
	for ns in s.nested_scenes {
		used[ns.local_id] = true
	}

	ns_remap := make(map[Local_ID]Local_ID, context.temp_allocator)
	for &ns in sf.nested_scenes {
		old := ns.local_id
		if used[old] {
			new_id := scene_next_id(s)
			ns_remap[old] = new_id
			ns.local_id = new_id
			used[new_id] = true
		} else {
			used[old] = true
		}
	}

	for &bc in sf.breadcrumbs {
		if new_inst, ok := ns_remap[bc.scene_instance]; ok {
			bc.scene_instance = new_inst
		}
	}

	bc_remap := make(map[Local_ID]Local_ID, context.temp_allocator)
	for &bc in sf.breadcrumbs {
		old := bc.local_id
		if used[old] {
			new_id := scene_next_id(s)
			bc_remap[old] = new_id
			bc.local_id = new_id
			used[new_id] = true
		} else {
			used[old] = true
		}
	}

	for &ns in sf.nested_scenes {
		if new_bid, ok := bc_remap[ns.host_breadcrumb_id]; ok {
			ns.host_breadcrumb_id = new_bid
		}
	}
}

_json_get_path :: proc(obj: json.Object, path: string) -> (json.Value, bool) {
    dot := strings.index_byte(path, '.')
    key := path if dot < 0 else path[:dot]
    val, ok := obj[key]
    if !ok do return nil, false
    if dot < 0 do return val, true
    sub, is_obj := val.(json.Object)
    if !is_obj do return nil, false
    return _json_get_path(sub, path[dot+1:])
}

_json_set_path :: proc(obj: ^json.Object, path: string, value: json.Value, allocator := context.allocator) {
    dot := strings.index_byte(path, '.')
    if dot < 0 {
        if existing, ok := obj[path]; ok {
            json.destroy_value(existing)
            obj[path] = json.clone_value(value, allocator)
        } else {
            obj[strings.clone(path, allocator)] = json.clone_value(value, allocator)
        }
        return
    }
    key := path[:dot]
    sub_val, has_sub := obj[key]
    sub_obj: json.Object
    if has_sub {
        if so, is_obj := sub_val.(json.Object); is_obj {
            sub_obj = so
        } else {
            json.destroy_value(sub_val)
            sub_obj = make(json.Object, 4, allocator)
        }
    } else {
        sub_obj = make(json.Object, 4, allocator)
    }
    _json_set_path(&sub_obj, path[dot+1:], value, allocator)
    if has_sub {
        obj[key] = sub_obj
    } else {
        obj[strings.clone(key, allocator)] = sub_obj
    }
}

nested_scene_apply_overrides :: proc(raw: []byte, overrides: []Override) -> []byte {
	if len(overrides) == 0 do return raw

	raw_copy := make([]byte, len(raw))
	defer delete(raw_copy)
	copy(raw_copy, raw)

	root_val: json.Value
	err := json.unmarshal_string(string(raw_copy), &root_val)
    if err != nil do return raw
    defer json.destroy_value(root_val)

    root_obj, is_obj := root_val.(json.Object)
    if !is_obj do return raw

    for ov in overrides {
        for key, section_val in root_obj {
            arr, is_arr := section_val.(json.Array)
            if !is_arr do continue
            for item, idx in arr {
                obj, ok := item.(json.Object)
                if !ok do continue
                lid, lid_ok := _json_local_id_of(obj)
                if !lid_ok || lid != ov.target do continue
                _json_set_path(&obj, ov.property_path, ov.value)
                arr[idx] = obj
                root_obj[key] = arr
                break
            }
        }
    }

    opts := json.Marshal_Options{spec = .JSON, pretty = false}
    data, merr := json.marshal(root_obj, opts)
    if merr != nil do return raw
    return data
}

_json_values_equal :: proc(a, b: json.Value) -> bool {
    switch av in a {
    case json.Null:
        _, ok := b.(json.Null)
        return ok
    case json.Boolean:
        bv, ok := b.(json.Boolean)
        return ok && av == bv
    case json.Integer:
        #partial switch bv in b {
        case json.Integer: return av == bv
        case json.Float:   return f64(av) == bv
        }
        return false
    case json.Float:
        #partial switch bv in b {
        case json.Float:   return av == bv
        case json.Integer: return av == f64(bv)
        }
        return false
    case json.String:
        bv, ok := b.(json.String)
        return ok && av == bv
    case json.Array:
        bv, ok := b.(json.Array)
        if !ok || len(av) != len(bv) do return false
        for i in 0..<len(av) {
            if !_json_values_equal(av[i], bv[i]) do return false
        }
        return true
    case json.Object:
        bv, ok := b.(json.Object)
        if !ok || len(av) != len(bv) do return false
        for k, v in av {
            bval, has := bv[k]
            if !has || !_json_values_equal(v, bval) do return false
        }
        return true
    }
    return false
}

_DIFF_TOP_EXCLUDED  :: []string{"parent", "children", "components"}
_DIFF_ALWAYS_EXCLUDED :: []string{"local_id"}

_json_diff_objects :: proc(base_obj, work_obj: json.Object, prefix: string, target_id: Local_ID, out: ^[dynamic]Override) {
    for key, work_val in work_obj {
        {
            excluded := false
            for ek in _DIFF_ALWAYS_EXCLUDED {
                if key == ek { excluded = true; break }
            }
            if excluded do continue
        }
        if prefix == "" {
            excluded := false
            for ek in _DIFF_TOP_EXCLUDED {
                if key == ek { excluded = true; break }
            }
            if excluded do continue
        }

        base_val, has_base := base_obj[key]
        full_path := prefix == "" ? key : strings.concatenate({prefix, ".", key}, context.temp_allocator)

        if !has_base {
            append(out, Override{
                target        = target_id,
                property_path = strings.clone(full_path),
                value         = json.clone_value(work_val),
            })
            continue
        }

        _, work_is_arr := work_val.(json.Array)
        _, base_is_arr := base_val.(json.Array)
        if work_is_arr || base_is_arr {
            if !_json_values_equal(base_val, work_val) {
                append(out, Override{
                    target        = target_id,
                    property_path = strings.clone(full_path),
                    value         = json.clone_value(work_val),
                })
            }
            continue
        }

        work_sub, work_is_obj := work_val.(json.Object)
        base_sub, base_is_obj := base_val.(json.Object)
        if work_is_obj && base_is_obj {
            _json_diff_objects(base_sub, work_sub, full_path, target_id, out)
            continue
        }

        if !_json_values_equal(base_val, work_val) {
            append(out, Override{
                target        = target_id,
                property_path = strings.clone(full_path),
                value         = json.clone_value(work_val),
            })
        }
    }
}

nested_scene_diff_overrides :: proc(base_raw: []byte, work_raw: []byte) -> [dynamic]Override {
	out := make([dynamic]Override)

	base_copy := make([]byte, len(base_raw))
	defer delete(base_copy)
	copy(base_copy, base_raw)
	work_copy := make([]byte, len(work_raw))
	defer delete(work_copy)
	copy(work_copy, work_raw)

	base_val: json.Value
	work_val: json.Value
	if json.unmarshal_string(string(base_copy), &base_val) != nil do return out
	if json.unmarshal_string(string(work_copy), &work_val) != nil {
		json.destroy_value(base_val)
		return out
	}
    defer json.destroy_value(base_val)
    defer json.destroy_value(work_val)

    base_root, base_ok := base_val.(json.Object)
    work_root, work_ok := work_val.(json.Object)
    if !base_ok || !work_ok do return out

    get_array :: proc(obj: json.Object, key: string) -> json.Array {
        v, ok := obj[key]
        if !ok do return nil
        arr, _ := v.(json.Array)
        return arr
    }

    array_keys := []string{"transforms", "cameras", "lifetimes", "players", "scripts", "sprite_renderers"}
    for section_key in array_keys {
        base_arr := get_array(base_root, section_key)
        work_arr := get_array(work_root, section_key)
        if len(work_arr) == 0 do continue
        for work_item in work_arr {
            wo, ok := work_item.(json.Object)
            if !ok do continue
            tid, tid_ok := _json_local_id_of(wo)
            if !tid_ok do continue
            for base_item in base_arr {
                bo, bok := base_item.(json.Object)
                if !bok do continue
                bid, bid_ok := _json_local_id_of(bo)
                if !bid_ok || bid != tid do continue
                _json_diff_objects(bo, wo, "", tid, &out)
                break
            }
        }
    }

    return out
}

NestedScene :: struct {
    local_id:             Local_ID,
    source_prefab:        Asset_GUID,
    transform_parent:     Local_ID,
    host_breadcrumb_id:   Local_ID,
    sibling_index:        int,
    source_root_id:       Local_ID `json:"-"`,
    expand_parent:        Transform_Handle `json:"-"`,
    overrides:            [dynamic]Override,
}

transform_is_nested_owned :: proc(tH: Transform_Handle) -> bool {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return false
    return t.nested_owned
}

transform_find_nested_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    current := tH
    for pool_valid(&w.transforms, Handle(current)) {
        t := pool_get(&w.transforms, Handle(current))
        if t == nil do return {}
        if !t.nested_owned {
            if scene_find_nested_scene_for_host(t.scene, current) != nil {
                return current
            }
        }
        current = Transform_Handle(t.parent.handle)
    }
    return {}
}

transform_nested_enclosing_host :: proc(tH: Transform_Handle) -> Transform_Handle {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(tH))
    if t == nil do return {}
    if !t.nested_owned {
        if scene_find_nested_scene_for_host(t.scene, tH) != nil {
            return tH
        }
        return {}
    }
    current := Transform_Handle(t.parent.handle)
    for pool_valid(&w.transforms, Handle(current)) {
        ct := pool_get(&w.transforms, Handle(current))
        if ct == nil do return {}
        if !ct.nested_owned {
            if scene_find_nested_scene_for_host(ct.scene, current) != nil {
                return current
            }
            return {}
        }
        current = Transform_Handle(ct.parent.handle)
    }
    return {}
}

// Single pass over transform slots: returns (first matching handle, count).
// Replaces the previous _count + _first pair which scanned the same slots twice.
_nested_scene_find_outer_non_nested :: proc(s: ^Scene, id: Local_ID) -> (Transform_Handle, int) {
	if s == nil || id == 0 do return {}, 0
	w := ctx_world()
	first: Transform_Handle = {}
	n := 0
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		tt := &slot.data
		if tt.scene != s || tt.local_id != id do continue
		if tt.nested_owned do continue
		if n == 0 {
			first = Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		}
		n += 1
	}
	return first, n
}

@(private = "file")
_transform_is_descendant_or_self :: proc(tH, ancestorH: Transform_Handle) -> bool {
	w := ctx_world()
	h := tH
	for _ in 0 ..< 4096 {
		if h == ancestorH do return true
		t := pool_get(&w.transforms, Handle(h))
		if t == nil do return false
		if t.parent.handle == {} do return false
		h = Transform_Handle(t.parent.handle)
	}
	return false
}

@(private = "file")
_nested_scene_scan_hosts_for_lid :: proc(s: ^Scene, ns: ^NestedScene, lid: Local_ID) -> (Transform_Handle, int) {
	if s == nil || ns == nil || lid == 0 do return {}, 0
	w := ctx_world()
	first: Transform_Handle = {}
	n := 0
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive do continue
		tt := &slot.data
		if tt.scene != s || tt.local_id != lid do continue
		tH := Transform_Handle(Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		if ns.expand_parent != {} {
			if !tt.nested_owned do continue
			if !_transform_is_descendant_or_self(tH, ns.expand_parent) do continue
		}
		if ns.host_breadcrumb_id != 0 {
			bc, ok := breadcrumb_get(s, ns.host_breadcrumb_id)
			if !ok || bc.scene_instance != ns.local_id do continue
			if !pptr_guid_is_empty(bc.scene_source.guid) do continue
			if bc.scene_source.local_id != lid do continue
		}
		if n == 0 do first = tH
		n += 1
	}
	return first, n
}

nested_row_direct_for_host :: proc(s: ^Scene, host_tH: Transform_Handle) -> ^NestedScene {
	ht := pool_get(&ctx_world().transforms, Handle(host_tH))
	if ht == nil || ht.scene != s || ht.nested_owned do return nil
	for &on in s.nested_scenes {
		if on.transform_parent == ht.local_id {
			return &on
		}
	}
	return nil
}

nested_scene_hosts_transform :: proc(s: ^Scene, ns: ^NestedScene, host_tH: Transform_Handle) -> bool {
	if s == nil do return false
	t := pool_get(&ctx_world().transforms, Handle(host_tH))
	if t == nil || t.scene != s do return false
	if ns.expand_parent != {} {
		if !_transform_is_descendant_or_self(host_tH, ns.expand_parent) {
			return false
		}
	}
	if ns.host_breadcrumb_id != 0 {
		bc, ok := breadcrumb_get(s, ns.host_breadcrumb_id)
		if !ok || bc.scene_instance != ns.local_id do return false
		if !pptr_guid_is_empty(bc.scene_source.guid) do return false
		lid := bc.scene_source.local_id

		oh := pool_get(&ctx_world().transforms, Handle(host_tH))
		if oh != nil && !oh.nested_owned {
			if dir := nested_row_direct_for_host(s, host_tH); dir != nil {
				if ns.source_prefab != dir.source_prefab {
					return false
				}
			}
		}

		if oh != nil && oh.nested_owned && oh.local_id == lid {
			if ns.expand_parent != {} {
				return transform_find_nested_host(host_tH) == ns.expand_parent
			}
			if dir := nested_row_direct_for_host(s, transform_find_nested_host(host_tH)); dir != nil {
				return ns.source_prefab != dir.source_prefab
			}
			return false
		}

		if h, ok2 := bimap_get(&s.local_ids, lid); ok2 {
			return h == Handle(host_tH)
		}
		want, n := _nested_scene_scan_hosts_for_lid(s, ns, lid)
		return n == 1 && want == host_tH
	}
	if ns.transform_parent != t.local_id do return false
	if h, ok2 := bimap_get(&s.local_ids, ns.transform_parent); ok2 {
		return h == Handle(host_tH)
	}
	want, n := _nested_scene_scan_hosts_for_lid(s, ns, ns.transform_parent)
	return n == 1 && want == host_tH
}

nested_scene_resolve_host_handle :: proc(s: ^Scene, ns: ^NestedScene) -> Transform_Handle {
	if s == nil || ns == nil do return {}

	lid := ns.transform_parent
	if ns.host_breadcrumb_id != 0 {
		bc, ok := breadcrumb_get(s, ns.host_breadcrumb_id)
		if !ok || bc.scene_instance != ns.local_id do return {}
		if !pptr_guid_is_empty(bc.scene_source.guid) do return {}
		lid = bc.scene_source.local_id
	}

	if ns.expand_parent != {} {
		first, n := _nested_scene_scan_hosts_for_lid(s, ns, lid)
		if n == 1 do return first
		return {}
	}

	if h, ok2 := bimap_get(&s.local_ids, lid); ok2 {
		cand := Transform_Handle(h)
		if nested_scene_hosts_transform(s, ns, cand) do return cand
	}
	first, n := _nested_scene_scan_hosts_for_lid(s, ns, lid)
	if n == 1 do return first
	return {}
}

nested_scene_attach_host_breadcrumb :: proc(s: ^Scene, ns: ^NestedScene, host_local_id: Local_ID) -> bool {
    if s == nil || ns == nil || host_local_id == 0 do return false
    peg := scene_next_id(s)
    if !scene_breadcrumb_put(
        s,
        Breadcrumb{
            local_id       = peg,
            scene_source   = PPtr{local_id = host_local_id, guid = Asset_GUID{}},
            scene_instance = ns.local_id,
        },
    ) {
        return false
    }
    ns.host_breadcrumb_id = peg
    return true
}

nested_scene_ensure_host_pegs :: proc(s: ^Scene) {
    if s == nil do return
    for &ns in s.nested_scenes {
        if ns.host_breadcrumb_id != 0 do continue
        if ns.transform_parent == 0 do continue
        nested_scene_attach_host_breadcrumb(s, &ns, ns.transform_parent)
    }
}

scene_find_nested_scene_for_host :: proc(s: ^Scene, host_tH: Transform_Handle) -> ^NestedScene {
	if s == nil do return nil
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(host_tH))
	if t == nil || t.scene != s do return nil
	for &ns in s.nested_scenes {
		if nested_scene_hosts_transform(s, &ns, host_tH) do return &ns
	}
	return nil
}

nested_scene_resolve :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    _nested_scene_unresolve(host_tH)

    ns := scene_find_nested_scene_for_host(host_t.scene, host_tH)
    if ns == nil do return
    guid := ns.source_prefab
    empty_guid := Asset_GUID{}
    if guid == empty_guid do return

    raw, ok := scene_lib[guid]
    if !ok {
        if !scene_lib_register(guid) do return
        raw, ok = scene_lib[guid]
        if !ok do return
    }

	baked := nested_scene_apply_overrides(raw, ns.overrides[:])
	baked_owned := len(ns.overrides) > 0 && raw_data(baked) != raw_data(raw)
	defer if baked_owned do delete(baked)

    sf: SceneFile
    if err := json.unmarshal(baked, &sf); err != nil do return
    defer scene_file_destroy(&sf)

    host_scene := host_t.scene
    ns.source_root_id = sf.root
    nested_before := len(host_scene.nested_scenes)
    nested_root_tH := _scene_load_as_child(&sf, host_tH, host_scene, ns.source_prefab, true)
    if nested_root_tH == {} do return

    for i in nested_before..<len(host_scene.nested_scenes) {
        host_scene.nested_scenes[i].expand_parent = host_tH
    }

    // Distribute `ns`'s deep overrides into the inner NS records we just
    // pulled in. A deep override has a breadcrumb-backed target whose source
    // PPtr names the inner prefab's GUID + local_id. We look those up and
    // append a translated override to whichever inner NS matches the
    // breadcrumb's source_prefab; that inner NS will then apply it when it
    // gets resolved recursively below.
    for i in nested_before..<len(host_scene.nested_scenes) {
        inner_m := &host_scene.nested_scenes[i]
        for &o in ns.overrides {
            bc, has_bc := breadcrumb_get(host_scene, o.target)
            if !has_bc do continue
            if bc.scene_source.guid != inner_m.source_prefab do continue
            if bc.scene_instance != ns.local_id do continue

            append(&inner_m.overrides, Override{
                target        = bc.scene_source.local_id,
                property_path = strings.clone(o.property_path),
                value         = json.clone_value(o.value),
            })
        }
    }

    nested_root := pool_get(&w.transforms, Handle(nested_root_tH))
    if nested_root == nil do return

    host_t = pool_get(&w.transforms, Handle(host_tH))

    for i in 0..<len(host_t.children) {
        if host_t.children[i].handle == Handle(nested_root_tH) {
            ordered_remove(&host_t.children, i)
            break
        }
    }

    for &c in nested_root.components {
        if world_pool_valid(w, c.handle) {
            raw_c := world_pool_get(w, c.handle)
            if raw_c != nil {
                base := cast(^CompData)raw_c
                base.owner = host_tH
                base.nested_owned = true
            }
        }
        append(&host_t.components, c)
    }
    clear(&nested_root.components)

    for child in nested_root.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        ct.parent = make_transform_ref(host_tH)
        append(&host_t.children, child)
        _mark_subtree_nested_owned(Transform_Handle(child.handle))
    }
    clear(&nested_root.children)

    transform_destroy(nested_root_tH)

    for child in host_t.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        if ct.nested_owned {
            _scene_resolve_nested_in_subtree(Transform_Handle(child.handle))
        }
    }
}

_mark_subtree_nested_owned :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return
    t.nested_owned = true
    for &c in t.components {
        raw := world_pool_get(w, c.handle)
        if raw == nil do continue
        base := cast(^CompData)raw
        base.nested_owned = true
    }
    for child in t.children {
        _mark_subtree_nested_owned(Transform_Handle(child.handle))
    }
}

_nested_scene_unresolve :: proc(host_tH: Transform_Handle) {
    w := ctx_world()
    host_t := pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    to_destroy_children := make([dynamic]Transform_Handle, 0, len(host_t.children), context.temp_allocator)
    for child in host_t.children {
        ct := pool_get(&w.transforms, child.handle)
        if ct == nil do continue
        if ct.nested_owned {
            append(&to_destroy_children, Transform_Handle(child.handle))
        }
    }
    for tH in to_destroy_children {
        transform_destroy(tH)
    }

    host_t = pool_get(&w.transforms, Handle(host_tH))
    if host_t == nil do return

    to_remove_comps := make([dynamic]Handle, 0, len(host_t.components), context.temp_allocator)
    for c in host_t.components {
        if !world_pool_valid(w, c.handle) do continue
        raw := world_pool_get(w, c.handle)
        if raw == nil do continue
        base := cast(^CompData)raw
        if base.nested_owned {
            append(&to_remove_comps, c.handle)
        }
    }
    for h in to_remove_comps {
        transform_remove_comp(host_tH, h)
    }
}

_scene_resolve_nested_in_subtree :: proc(root_tH: Transform_Handle) {
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(root_tH))
    if t == nil do return

    if scene_find_nested_scene_for_host(t.scene, root_tH) != nil {
        nested_scene_resolve(root_tH)
        return
    }

    children_copy := make([]Ref, len(t.children), context.temp_allocator)
    copy(children_copy, t.children[:])
    for child in children_copy {
        _scene_resolve_nested_in_subtree(Transform_Handle(child.handle))
    }
}

scene_resolve_all_nested :: proc(root_tH: Transform_Handle) {
    _scene_resolve_nested_in_subtree(root_tH)
}

nested_scene_has_override :: proc(ns: ^NestedScene, target_id: Local_ID, property_path: string) -> bool {
    if ns == nil do return false
    for &ov in ns.overrides {
        if ov.target == target_id && ov.property_path == property_path do return true
    }
    return false
}

_nested_revert_field_ptr :: proc(ptr: rawptr, tid: typeid, path: string) -> (rawptr, typeid, bool) {
    dot := strings.index_byte(path, '.')
    key := path if dot < 0 else path[:dot]
    names := reflect.struct_field_names(tid)
    types := reflect.struct_field_types(tid)
    offsets := reflect.struct_field_offsets(tid)
    for i in 0..<len(names) {
        if names[i] != key do continue
        field_ptr := rawptr(uintptr(ptr) + offsets[i])
        if dot < 0 do return field_ptr, types[i].id, true
        return _nested_revert_field_ptr(field_ptr, types[i].id, path[dot+1:])
    }
    return nil, nil, false
}

nested_scene_revert_override :: proc(ns: ^NestedScene, target_id: Local_ID, property_path: string) {
    if ns == nil do return

    w := ctx_world()

    live_ptr: rawptr
    live_tid: typeid
    found := false

    for i in 0..<len(w.transforms.slots) {
        slot := &w.transforms.slots[i]
        if !slot.alive do continue
        t := &slot.data
        is_target := t.local_id == target_id && t.nested_owned
        is_host    := target_id == ns.source_root_id && t.local_id == ns.transform_parent
        if !is_target && !is_host do continue
        field_ptr, field_tid, ok := _nested_revert_field_ptr(t, Transform, property_path)
        if ok {
            live_ptr = field_ptr
            live_tid = field_tid
            found = true
        }
        break
    }

    if !found {
        for tk in TypeKey {
            if tk == INVALID_TYPE_KEY || tk == .Transform do continue
            entry := w.pool_table[tk]
            if entry.get_fn == nil do continue
            comp_tid := get_typeid_by_type_key(tk)
            if comp_tid == nil do continue
            for i in 0..<len(w.transforms.slots) {
                slot := &w.transforms.slots[i]
                if !slot.alive do continue
                for c in slot.data.components {
                    if c.handle.type_key != tk do continue
                    comp_ptr := world_pool_get(w, c.handle)
                    if comp_ptr == nil do continue
                    base := cast(^CompData)comp_ptr
                    if base.local_id != target_id do continue
                    field_ptr, field_tid, ok := _nested_revert_field_ptr(comp_ptr, comp_tid, property_path)
                    if ok {
                        live_ptr = field_ptr
                        live_tid = field_tid
                        found = true
                    }
                    break
                }
                if found do break
            }
            if found do break
        }
    }

    for i in 0..<len(ns.overrides) {
        ov := &ns.overrides[i]
        if ov.target != target_id || ov.property_path != property_path do continue

        if found && live_ptr != nil {
            base_raw, has_base := scene_lib[ns.source_prefab]
            if has_base {
                base_copy := make([]byte, len(base_raw))
                defer delete(base_copy)
                copy(base_copy, base_raw)
                base_val: json.Value
                if json.unmarshal_string(string(base_copy), &base_val) == nil {
                    defer json.destroy_value(base_val)
                    base_root, is_obj := base_val.(json.Object)
                    if is_obj {
                        find_by_id :: proc(arr: json.Array, id: Local_ID) -> (json.Object, bool) {
                            for item in arr {
                                obj, ok := item.(json.Object)
                                if !ok do continue
                                lid, lid_ok := _json_local_id_of(obj)
                                if lid_ok && lid == id do return obj, true
                            }
                            return {}, false
                        }
                        for _, section_val in base_root {
                            arr, is_arr := section_val.(json.Array)
                            if !is_arr do continue
                            item_obj, item_found := find_by_id(arr, target_id)
                            if !item_found do continue
                            base_field_json, path_ok := _json_get_path(item_obj, property_path)
                            if path_ok {
                                if field_bytes, merr := json.marshal(base_field_json, {spec = .JSON}); merr == nil {
                                    defer delete(field_bytes)
                                    type_cleanup_by_typeid(live_tid, live_ptr)
                                    if ptr_tid, ptr_ok := get_pointer_typeid_by_typeid(live_tid); ptr_ok {
                                        json.unmarshal_any(field_bytes, any{&live_ptr, ptr_tid})
                                    }
                                }
                            }
                            break
                        }
                    }
                }
            }
        }

        delete(ov.property_path)
        json.destroy_value(ov.value)
        ordered_remove(&ns.overrides, i)
        return
    }
}

nested_scene_add :: proc(s: ^Scene, source_prefab: Asset_GUID, host_tH: Transform_Handle, sibling_index: int) -> ^NestedScene {
    if s == nil do return nil
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(host_tH))
    if t == nil do return nil
    ns := NestedScene{
        local_id         = scene_next_id(s),
        source_prefab    = source_prefab,
        transform_parent = t.local_id,
        sibling_index    = sibling_index,
    }
    append(&s.nested_scenes, ns)
    ns_ptr := &s.nested_scenes[len(s.nested_scenes) - 1]
    nested_scene_attach_host_breadcrumb(s, ns_ptr, t.local_id)
    return ns_ptr
}

nested_scene_remove :: proc(s: ^Scene, host_tH: Transform_Handle) {
    if s == nil do return
    w := ctx_world()
    t := pool_get(&w.transforms, Handle(host_tH))
    if t == nil do return
    for i in 0 ..< len(s.nested_scenes) {
        if nested_scene_hosts_transform(s, &s.nested_scenes[i], host_tH) {
            ns_lid := s.nested_scenes[i].local_id
            breadcrumb_clear_for_nested_scene(s, ns_lid)
            ordered_remove(&s.nested_scenes, i)
            return
        }
    }
}

scene_nested_scene_by_local_id :: proc(s: ^Scene, ns_local_id: Local_ID) -> (^NestedScene, bool) {
    if s == nil do return nil, false
    for &ns in s.nested_scenes {
        if ns.local_id == ns_local_id do return &ns, true
    }
    return nil, false
}

BREADCRUMB_SYNTH_HANDLE_INDEX_BASE :: u32(0x8000_0000)

breadcrumb_alloc_synthetic_handle :: proc(s: ^Scene) -> Handle {
    s.breadcrumb_synth_seq += 1
    return Handle{
        index      = BREADCRUMB_SYNTH_HANDLE_INDEX_BASE + s.breadcrumb_synth_seq,
        generation = 0,
        type_key   = INVALID_TYPE_KEY,
    }
}

scene_breadcrumb_put :: proc(s: ^Scene, bc: Breadcrumb) -> bool {
    if s == nil || bc.local_id == 0 do return false
    if _, had := s.breadcrumb_data[bc.local_id]; had {
        bimap_remove_by_key(&s.local_ids, bc.local_id)
    }
    h := breadcrumb_alloc_synthetic_handle(s)
    bimap_insert(&s.local_ids, bc.local_id, h)
    s.breadcrumb_data[bc.local_id] = bc
    return true
}

breadcrumb_get :: proc(s: ^Scene, placeholder_local_id: Local_ID) -> (Breadcrumb, bool) {
    if s == nil || placeholder_local_id == 0 do return {}, false
    bc, ok := s.breadcrumb_data[placeholder_local_id]
    return bc, ok
}

breadcrumb_placeholder :: proc(s: ^Scene, scene_instance: Local_ID, src: PPtr) -> (Local_ID, bool) {
    if s == nil || scene_instance == 0 do return 0, false
    for _, bc in s.breadcrumb_data {
        if bc.scene_instance == scene_instance && pptr_equals(bc.scene_source, src) {
            return bc.local_id, true
        }
    }
    return 0, false
}

breadcrumb_create :: proc(s: ^Scene, scene_instance: Local_ID, src: PPtr) -> (Local_ID, bool) {
    if s == nil || scene_instance == 0 do return 0, false
    if _, ok := scene_nested_scene_by_local_id(s, scene_instance); !ok do return 0, false
    if ph, ok := breadcrumb_placeholder(s, scene_instance, src); ok {
        return ph, true
    }
    lid := scene_next_id(s)
    if !scene_breadcrumb_put(s, Breadcrumb{
        local_id       = lid,
        scene_source   = src,
        scene_instance = scene_instance,
    }) {
        return 0, false
    }
    return lid, true
}

breadcrumb_materialize_target :: proc(s: ^Scene, scene_instance: Local_ID, target: PPtr) -> (PPtr, bool) {
    if s == nil || scene_instance == 0 do return {}, false
    if pptr_guid_is_empty(target.guid) {
        return target, true
    }
    peg, ok := breadcrumb_create(s, scene_instance, target)
    if !ok do return {}, false
    return PPtr{local_id = peg, guid = Asset_GUID{}}, true
}

breadcrumb_remove :: proc(s: ^Scene, placeholder_local_id: Local_ID) -> bool {
    if s == nil || placeholder_local_id == 0 do return false
    if _, ok := s.breadcrumb_data[placeholder_local_id]; !ok do return false
    bimap_remove_by_key(&s.local_ids, placeholder_local_id)
    delete_key(&s.breadcrumb_data, placeholder_local_id)
    return true
}

breadcrumb_clear_for_nested_scene :: proc(s: ^Scene, scene_instance: Local_ID) {
    if s == nil || scene_instance == 0 do return
    to_del := make([dynamic]Local_ID, 0, 8, context.temp_allocator)
    for _, bc in s.breadcrumb_data {
        if bc.scene_instance == scene_instance {
            append(&to_del, bc.local_id)
        }
    }
    for lid in to_del {
        breadcrumb_remove(s, lid)
    }
}

breadcrumb_is_placeholder :: proc(s: ^Scene, local_id: Local_ID) -> bool {
    if s == nil || local_id == 0 do return false
    _, ok := s.breadcrumb_data[local_id]
    return ok
}
