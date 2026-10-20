# Aether v1 — Revisión HIG

| Regla | Implementación | ✓/✗ |
|---|---|---|
| Menús estándar + Harvester, Cosmos, Control | AetherCommands | ✓ |
| Toda acción con atajo (§8 del overview) | AetherCommands + toolbars | ✓ |
| Menús dinámicos (Pausa/Reproducir, deshabilitados sin selección) | AetherCommands | ✓ |
| Menú contextual en filas de búsqueda, cola, historial, Master | TrackTable, JobRow, HistoryView, CosmosBrowserView | ✓ |
| Ventana redimensionable, mínimo 960×600, estado restaurado | Window + defaultSize | ✓ |
| Toolbar unificada, búsqueda en toolbar | windowToolbarStyle(.unified), .searchable(placement: .toolbar) | ✓ |
| Sidebar colapsable (⌃⌘S), source list | SidebarCommands, .listStyle(.sidebar) | ✓ |
| Badges en sidebar (Cola, Por clasificar, Revisar) | SidebarView | ✓ |
| Esc cierra popovers/hojas; Return = acción por defecto | sheets/popovers del sistema, .defaultAction | ✓ |
| Delete / ⌘⌫ elimina con deshacer | CosmosBrowserView, HarvesterQueueView | ✓ |
| Quick Look (⌘Y) | CosmosCommands | ✓ |
| Hover y cursores en elementos interactivos | botones .borderless del sistema | ✓ |
| Arrastrar y soltar (filas → carpetas) | TableRow.draggable + dropDestination | ✓ |
| Notificaciones solo en segundo plano | HarvesterStore.notifyBatchFinished | ✓ |
| Dock badge con descargas activas + menú del Dock | HarvesterStore, DockMenuBuilder | ✓ |
| Liquid Glass solo en navegación/controles; contenido opaco; sin vidrio sobre vidrio | TransportBar, sistema | ✓ |
| Reduce Transparency / Motion / Increase Contrast | Tokens, TransportBar | ✓ |
| Colores semánticos + acento del sistema en controles | Tokens | ✓ |
