package engine

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"
import "base:runtime"

_remap_refs_in_value :: proc(ptr: rawptr, ti: ^runtime.Type_Info, remap: ^map[Local_ID]Local_ID) {
	if ptr == nil || ti == nil do return
	base := runtime.type_info_base(ti)
	if base == nil do return

	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		tid := ti.id
		if tid == typeid_of(PPtr) {
			pptr := cast(^PPtr)ptr
			if pptr.local_id != 0 {
				if new_id, ok := remap[pptr.local_id]; ok {
					pptr.local_id = new_id
				}
			}
			return
		}
		if tid == typeid_of(Ref) {
			ref := cast(^Ref)ptr
			if ref.pptr.local_id != 0 {
				if new_id, ok := remap[ref.pptr.local_id]; ok {
					ref.pptr.local_id = new_id
				}
			}
			return
		}
		if tid == typeid_of(Ref_Local) || tid == typeid_of(Owned) {
			rl := cast(^Ref_Local)ptr
			if rl.local_id != 0 {
				if new_id, ok := remap[rl.local_id]; ok {
					rl.local_id = new_id
				}
			}
			return
		}

		count := int(info.field_count)
		for i in 0..<count {
			field_ptr := rawptr(uintptr(ptr) + info.offsets[i])
			_remap_refs_in_value(field_ptr, info.types[i], remap)
		}

	case runtime.Type_Info_Union:
		tag_ptr := rawptr(uintptr(ptr) + info.tag_offset)
		tag: i64
		switch info.tag_type.size {
		case 1: tag = i64((cast(^u8)tag_ptr)^)
		case 2: tag = i64((cast(^u16)tag_ptr)^)
		case 4: tag = i64((cast(^u32)tag_ptr)^)
		case 8: tag = i64((cast(^u64)tag_ptr)^)
		}
		idx := tag if info.no_nil else tag - 1
		if idx < 0 || int(idx) >= len(info.variants) do return
		variant_ti := info.variants[idx]
		_remap_refs_in_value(ptr, variant_ti, remap)

	case runtime.Type_Info_Dynamic_Array:
		dyn := cast(^runtime.Raw_Dynamic_Array)ptr
		if dyn.data == nil || dyn.len == 0 do return
		elem_size := info.elem_size
		for i in 0..<dyn.len {
			elem_ptr := rawptr(uintptr(dyn.data) + uintptr(i * elem_size))
			_remap_refs_in_value(elem_ptr, info.elem, remap)
		}

	case runtime.Type_Info_Array:
		elem_size := info.elem_size
		for i in 0..<info.count {
			elem_ptr := rawptr(uintptr(ptr) + uintptr(i * elem_size))
			_remap_refs_in_value(elem_ptr, info.elem, remap)
		}
	}
}

_collect_transform_tree :: proc(w: ^World, tH: Transform_Handle, sf: ^SceneFile) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	if t.nested_owned do return

	t_copy := t^
	t_copy.name = strings.clone(t.name)
	t_copy.children = make([dynamic]Ref, 0, len(t.children))
	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned do continue
		append(&t_copy.children, child)
	}
	t_copy.components = make([dynamic]Owned, 0, len(t.components))
	for c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		raw := world_pool_get(w, c.handle)
		if raw != nil {
			base := cast(^CompData)raw
			if base.nested_owned do continue
		}
		append(&t_copy.components, c)
	}
	append(&sf.transforms, t_copy)

	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		raw := world_pool_get(w, c.handle)
		if raw != nil {
			base := cast(^CompData)raw
			if base.nested_owned do continue
		}
		world_pool_collect(w, c.handle, sf)
	}

	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned do continue
		_collect_transform_tree(w, Transform_Handle(child.handle), sf)
	}
}

// Walks the nested-owned subtree for override capture. `outer_ns` is the
// NestedScene we're capturing for; `outer_host` is the live transform it
// resolves to. Items belonging to a *different* NS (inner prefabs nested under
// this one) live in their own namespace and would collide with the outer
// prefab's local_ids during diff (see Unity's PrefabInstance/m_Modifications
// model — overrides only address items in the immediate prefab). When we hit
// such a boundary we still serialize the host transform itself (it is the
// outer prefab's content), but stop pulling in its components and children.
_collect_nested_owned_subtree :: proc(
	w: ^World,
	tH: Transform_Handle,
	sf: ^SceneFile,
	root_local_id_override: Local_ID = 0,
	outer_ns: ^NestedScene = nil,
	outer_host: Transform_Handle = {},
) {
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return

	is_inner_boundary := false
	if outer_ns != nil && tH != outer_host {
		owning := scene_find_nested_scene_for_host(t.scene, tH)
		if owning != nil && owning != outer_ns do is_inner_boundary = true
	}

	t_copy := t^
	if root_local_id_override != 0 do t_copy.local_id = root_local_id_override
	t_copy.name = strings.clone(t.name)
	t_copy.children = make([dynamic]Ref, 0, len(t.children))
	if !is_inner_boundary {
		for child in t.children {
			ct := pool_get(&w.transforms, child.handle)
			if ct != nil do append(&t_copy.children, child)
		}
	}
	t_copy.components = make([dynamic]Owned, 0, len(t.components))
	if !is_inner_boundary {
		for c in t.components {
			if c.handle.type_key == INVALID_TYPE_KEY do continue
			raw := world_pool_get(w, c.handle)
			if raw != nil {
				base := cast(^CompData)raw
				if base.nested_owned do append(&t_copy.components, c)
			}
		}
	}
	append(&sf.transforms, t_copy)

	if is_inner_boundary do return

	for &c in t.components {
		if c.handle.type_key == INVALID_TYPE_KEY do continue
		raw := world_pool_get(w, c.handle)
		if raw == nil do continue
		base := cast(^CompData)raw
		if base.nested_owned do world_pool_collect(w, c.handle, sf)
	}

	for child in t.children {
		ct := pool_get(&w.transforms, child.handle)
		if ct != nil && ct.nested_owned {
			_collect_nested_owned_subtree(w, Transform_Handle(child.handle), sf, 0, outer_ns, outer_host)
		}
	}
}

_nested_scene_capture_overrides :: proc(s: ^Scene, ns: ^NestedScene) {
	w := ctx_world()
	empty_guid := Asset_GUID{}
	if ns.source_prefab == empty_guid do return

	host_tH := nested_scene_resolve_host_handle(s, ns)
	if host_tH == {} do return

	host_t := pool_get(&w.transforms, Handle(host_tH))
	if host_t == nil do return

	base_raw, has_base := scene_lib[ns.source_prefab]
	if !has_base {
		if !scene_lib_register(ns.source_prefab) do return
		base_raw, has_base = scene_lib[ns.source_prefab]
		if !has_base do return
	}

	base_copy := make([]byte, len(base_raw))
	defer delete(base_copy)
	copy(base_copy, base_raw)

	prefab_root_id: Local_ID
	{
		base_sf: SceneFile
		if json.unmarshal(base_copy, &base_sf) == nil {
			prefab_root_id = base_sf.root
			scene_file_destroy(&base_sf)
		}
	}

	work_sf := SceneFile{}
	work_sf.root = prefab_root_id != 0 ? prefab_root_id : host_t.local_id
	_collect_nested_owned_subtree(w, host_tH, &work_sf, prefab_root_id, ns, host_tH)
	defer scene_file_destroy_shallow(&work_sf)

	opts := json.Marshal_Options{spec = .JSON, pretty = false}
	work_raw, werr := json.marshal(work_sf, opts)
	if werr != nil {
		fmt.printf("[Scene] Failed to marshal working copy for override capture: %v\n", werr)
		return
	}
	defer delete(work_raw)

	new_overrides := nested_scene_diff_overrides(base_raw, work_raw)

	// Cleanup: drop overrides whose target local_id no longer exists in the
	// source prefab. This protects against orphans left when the prefab is
	// edited to remove the targeted item; nothing in the diff should produce
	// these, but old saves and merges sometimes do.
	_drop_overrides_with_missing_targets(&new_overrides, base_raw)

	for &ov in ns.overrides {
		delete(ov.property_path)
		json.destroy_value(ov.value)
	}
	delete(ns.overrides)
	ns.overrides = new_overrides
}

// Returns the set of local_ids that appear in the prefab base file's section
// arrays. Used by the override cleanup pass.
_collect_prefab_local_ids :: proc(base_raw: []byte, allocator := context.allocator) -> (map[Local_ID]bool, bool) {
	out := make(map[Local_ID]bool, 0, allocator)
	base_copy := make([]byte, len(base_raw), context.temp_allocator)
	copy(base_copy, base_raw)
	val: json.Value
	if json.unmarshal_string(string(base_copy), &val) != nil {
		delete(out)
		return nil, false
	}
	defer json.destroy_value(val)
	root, is_obj := val.(json.Object)
	if !is_obj {
		delete(out)
		return nil, false
	}
	for _, section_val in root {
		arr, is_arr := section_val.(json.Array)
		if !is_arr do continue
		for item in arr {
			obj, ok := item.(json.Object)
			if !ok do continue
			lid, lid_ok := _scene_file_local_id_of(obj)
			if lid_ok do out[lid] = true
		}
	}
	return out, true
}

_scene_file_local_id_of :: proc(obj: json.Object) -> (Local_ID, bool) {
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

_drop_overrides_with_missing_targets :: proc(overrides: ^[dynamic]Override, base_raw: []byte) {
	ids, ok := _collect_prefab_local_ids(base_raw)
	if !ok do return
	defer delete(ids)
	write := 0
	for i in 0 ..< len(overrides) {
		ov := overrides[i]
		if ids[ov.target] {
			overrides[write] = ov
			write += 1
		} else {
			delete(ov.property_path)
			json.destroy_value(ov.value)
		}
	}
	resize(overrides, write)
}

_find_ns_by_local_id :: proc(s: ^Scene, ns_local_id: Local_ID) -> (^NestedScene, bool) {
	for &ns in s.nested_scenes {
		if ns.local_id == ns_local_id do return &ns, true
	}
	return nil, false
}

// Walks `m.expand_parent` up the transform tree until it hits a non-nested-owned
// transform. That transform is the host of the outermost native NS containing
// `m` — used to figure out which native NS should carry `m`'s overrides as deep
// overrides at save time.
_native_host_for_inner_ns :: proc(s: ^Scene, m: ^NestedScene) -> Transform_Handle {
	if m.expand_parent == {} do return {}
	w := ctx_world()
	h := m.expand_parent
	for _ in 0 ..< 4096 {
		t := pool_get(&w.transforms, Handle(h))
		if t == nil do return {}
		if !t.nested_owned do return h
		if t.parent.handle == {} do return {}
		h = Transform_Handle(t.parent.handle)
	}
	return {}
}

// For each inner NS downstream of `n`, allocate a breadcrumb mapping its target
// local_id (in the inner prefab's namespace) to a fresh outer-bimap local_id
// and emit the override on `n` with that outer id. The breadcrumb is what lets
// us reload + reapply: on next load, breadcrumb_get(target) tells the resolver
// which inner prefab the override is destined for, and where inside it.
//
// Currently handles 2-level depth only (outer file → bullet → c.scene). Deeper
// chains (3+) would require intermediate breadcrumbs the outer file doesn't
// know how to emit — the inner NS's own deep overrides would need to be
// preserved, but inner NS records aren't persisted in the outer file. Punt.
_propagate_deep_overrides_into :: proc(s: ^Scene, n: ^NestedScene) {
	n_host := nested_scene_resolve_host_handle(s, n)
	if n_host == {} do return

	for &m in s.nested_scenes {
		if m.expand_parent == {} do continue
		if _native_host_for_inner_ns(s, &m) != n_host do continue
		if len(m.overrides) == 0 do continue

		for ov in m.overrides {
			mat, mok := breadcrumb_materialize_target(
				s,
				n.local_id,
				PPtr{local_id = ov.target, guid = m.source_prefab},
			)
			if !mok do continue
			outer_lid := mat.local_id

			already := false
			for &existing in n.overrides {
				if existing.target == outer_lid && existing.property_path == ov.property_path {
					already = true
					break
				}
			}
			if already do continue

			append(&n.overrides, Override{
				target        = outer_lid,
				property_path = strings.clone(ov.property_path),
				value         = json.clone_value(ov.value),
			})
		}
	}
}

scene_save :: proc(s: ^Scene, path: string) -> bool {
	if s == nil do return false
	w := ctx_world()

	for &ns in s.nested_scenes {
		_nested_scene_capture_overrides(s, &ns)
	}
	// After every NS has its fresh shallow override list, lift inner-NS
	// overrides into their owning native NS as breadcrumb-backed deep
	// overrides. Done as a separate pass so the inner overrides we read are
	// already up-to-date.
	for &ns in s.nested_scenes {
		if ns.expand_parent != {} do continue
		_propagate_deep_overrides_into(s, &ns)
	}

	sf := SceneFile{}
	sf.next_local_id = s.next_local_id

	// Only persist NS records that belong to this scene file. Records with
	// `expand_parent` set were pulled in from inner prefabs during resolve
	// (see nested_scene_resolve at nested_scene.odin:582) and live in
	// `s.nested_scenes` purely for in-memory operations — saving them would
	// duplicate the inner prefab's metadata into this file and, on reload,
	// turn the inner host transforms into ghost nested-scene hosts.
	native_ns_lids := make(map[Local_ID]bool, 0, context.temp_allocator)
	for &ns in s.nested_scenes {
		if ns.expand_parent != {} do continue
		append(&sf.nested_scenes, ns)
		native_ns_lids[ns.local_id] = true
	}
	for _, bc in s.breadcrumb_data {
		// Keep only breadcrumbs whose owning NestedScene is also native (or
		// that aren't host pegs at all — cross-scene Handle pegs survive).
		if native_ns_lids[bc.scene_instance] {
			append(&sf.breadcrumbs, bc)
		} else if _, has_owner := _find_ns_by_local_id(s, bc.scene_instance); !has_owner {
			append(&sf.breadcrumbs, bc)
		}
	}

	if s.root.handle != {} {
		t := pool_get(&w.transforms, s.root.handle)
		if t != nil {
			sf.root = t.local_id
			_collect_transform_tree(w, Transform_Handle(s.root.handle), &sf)
		}
	}

	// Repair next_local_id: any local_id present in the file must be strictly
	// less than next_local_id. Otherwise a future scene_next_id() collides with
	// an existing entity, which on reload can cause a regular transform to be
	// matched as the host of a NestedScene record.
	bump :: proc(m: ^Local_ID, v: Local_ID) { if v >= m^ do m^ = v + 1 }
	for &tr in sf.transforms {
		bump(&sf.next_local_id, tr.local_id)
		for &c in tr.components do bump(&sf.next_local_id, c.local_id)
	}
	for &c in sf.cameras          do bump(&sf.next_local_id, c.local_id)
	for &c in sf.lifetimes        do bump(&sf.next_local_id, c.local_id)
	for &c in sf.players          do bump(&sf.next_local_id, c.local_id)
	for &c in sf.scripts          do bump(&sf.next_local_id, c.local_id)
	for &c in sf.sprite_renderers do bump(&sf.next_local_id, c.local_id)
	for &ns in sf.nested_scenes   do bump(&sf.next_local_id, ns.local_id)
	for &bc in sf.breadcrumbs     do bump(&sf.next_local_id, bc.local_id)
	s.next_local_id = sf.next_local_id

	opts := json.Marshal_Options{
		spec       = .JSON,
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	data, err := json.marshal(sf, opts)
	if err != nil {
		fmt.printf("[Scene] Failed to marshal scene: %v\n", err)
		scene_file_destroy_shallow(&sf)
		return false
	}
	defer delete(data)

	scene_file_destroy_shallow(&sf)

	if write_err := os.write_entire_file(path, data); write_err != nil {
		fmt.printf("[Scene] Failed to write file: %s — %v\n", path, write_err)
		return false
	}

	if s.path != path {
		delete(s.path)
		s.path = strings.clone(path)
	}

	fmt.printf("[Scene] Saved scene to %s\n", path)
	return true
}

scene_file_load :: proc(filepath: string) -> (SceneFile, bool) {
	data, read_ok := os.read_entire_file(filepath, context.allocator)
	if read_ok != nil {
		fmt.printf("[Scene] Failed to read file: %s\n", filepath)
		return {}, false
	}
	defer delete(data)

	sf: SceneFile
	unmarshal_err := json.unmarshal(data, &sf)
	if unmarshal_err != nil {
		fmt.printf("[Scene] Failed to unmarshal scene: %v\n", unmarshal_err)
		return {}, false
	}

	return sf, true
}

resolve_handle :: proc(local_id: Local_ID, id_map: map[Local_ID]Handle) -> (Handle, bool) {
	if local_id == 0 do return {}, false
	if h, ok := id_map[local_id]; ok {
		return h, true
	}
	return {}, false
}

scene_load_single_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	scene_guid: Asset_GUID = {}
	if g, gok := asset_db_get_guid(path); gok {
		scene_guid = Asset_GUID(g)
	}
	s := _scene_load_single(&sf, scene_guid)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

scene_load_additive_path :: proc(path: string) -> ^Scene {
	sf, ok := scene_file_load(path)
	if !ok do return nil
	defer scene_file_destroy(&sf)

	scene_guid: Asset_GUID = {}
	if g, gok := asset_db_get_guid(path); gok {
		scene_guid = Asset_GUID(g)
	}
	s := _scene_load_additive(&sf, scene_guid)
	if s != nil {
		s.path = strings.clone(path)
	}
	return s
}

scene_copy_subtree :: proc(tH: Transform_Handle) -> []byte {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return nil

	sf := SceneFile{}
	sf.root = t.local_id
	_collect_transform_tree(w, tH, &sf)
	defer scene_file_destroy_shallow(&sf)

	opts := json.Marshal_Options{spec = .JSON, pretty = false}
	data, err := json.marshal(sf, opts)
	if err != nil {
		fmt.printf("[Scene] Failed to marshal subtree: %v\n", err)
		delete(data)
		return nil
	}
	return data
}

scene_paste_subtree :: proc(data: []byte, parent: Transform_Handle) -> Transform_Handle {
	if parent == {} || len(data) == 0 do return {}
	w := ctx_world()
	if !pool_valid(&w.transforms, Handle(parent)) do return {}

	sf: SceneFile
	if err := json.unmarshal(data, &sf); err != nil {
		fmt.printf("[Scene] Failed to unmarshal subtree: %v\n", err)
		return {}
	}
	defer scene_file_destroy(&sf)

	pt := pool_get(&w.transforms, Handle(parent))
	s := pt.scene

	_scene_file_remap_local_ids(&sf, s)
	root_tH := _scene_load_as_child(&sf, parent, s)
	if root_tH != {} && !ctx_get().is_playmode {
		_scene_resolve_nested_in_subtree(root_tH)
	}
	return root_tH
}

scene_duplicate_subtree :: proc(tH: Transform_Handle) -> Transform_Handle {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return {}

	parent := Transform_Handle(t.parent.handle)
	if !pool_valid(&w.transforms, Handle(parent)) do return {}

	data := scene_copy_subtree(tH)
	defer delete(data)

	return scene_paste_subtree(data, parent)
}
