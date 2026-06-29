#Requires AutoHotkey v2.0

global uiLang := "en"

I18nData() {
    static T := Map(
        "en", Map(
            "app_title", "Broken Key Remapper Pro",
            "subtitle", "Smart predictive remapping + AI",
            "mapping_hdr", "Pressable Key  ->  Output Group (comma separated)",
            "col_pressable", "Pressable", "col_outputs", "Outputs", "col_current", "Current",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Uses",
            "btn_add", "Add / Edit", "btn_remove", "Remove", "btn_clear", "Clear all",
            "btn_export", "Export", "btn_import", "Import",
            "mode_lbl", "Current mode:", "mode_normal", "  NORMAL MODE - OFF", "mode_mapped", "  MAPPED MODE - ON",
            "chk_hud", "Show floating prediction HUD",
            "btn_toggle", "Turn Mapping ON (F12)", "btn_toggle_off", "Turn Mapping OFF (F12)",
            "btn_wizard", "Setup Wizard", "btn_stats", "Statistics",
            "lang_lbl", "Language:",
            "hotkeys", "F12 toggle mapping  |  Ctrl+F12 add  |  Shift+key cycles letters",
            "tray_show", "Show Window", "tray_toggle", "Toggle Mapping (F12)",
            "tray_stats", "Statistics...", "tray_wizard", "Setup Wizard", "tray_exit", "Exit",
            "hud_cycle", "cycles",
            "via", "Engine",
            "hud_on", "Prediction HUD enabled",
            "hud_off", "Prediction HUD disabled",
            "stats_title", "Statistics",
            "stats_predictions", "Predictions",
            "stats_ai", "AI assists",
            "stats_session", "Session"
        ),
        "ru", Map(
            "app_title", "Ремаппер сломанных клавиш Pro",
            "subtitle", "Умное предсказание + ИИ",
            "mapping_hdr", "Рабочая клавиша  ->  Группа вывода (через запятую)",
            "col_pressable", "Клавиша", "col_outputs", "Вывод", "col_current", "Сейчас",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Исп.",
            "btn_add", "Добавить", "btn_remove", "Удалить", "btn_clear", "Очистить",
            "btn_export", "Экспорт", "btn_import", "Импорт",
            "mode_lbl", "Режим:", "mode_normal", "  ОБЫЧНЫЙ - ВЫКЛ", "mode_mapped", "  РЕМАП - ВКЛ",
            "chk_hud", "Показывать HUD предсказаний",
            "btn_toggle", "Включить ремап (F12)", "btn_toggle_off", "Выключить ремап (F12)",
            "btn_wizard", "Мастер настройки", "btn_stats", "Статистика",
            "lang_lbl", "Язык:",
            "hotkeys", "F12 вкл/выкл  |  Ctrl+F12 добавить  |  Shift+клавиша — перебор",
            "tray_show", "Показать окно", "tray_toggle", "Ремап (F12)",
            "tray_stats", "Статистика...", "tray_wizard", "Мастер", "tray_exit", "Выход",
            "hud_cycle", "перебор",
            "via", "Движок",
            "hud_on", "HUD включён",
            "hud_off", "HUD выключен",
            "stats_title", "Статистика",
            "stats_predictions", "Предсказания",
            "stats_ai", "Помощь ИИ",
            "stats_session", "Сессия"
        ),
        "es", Map(
            "app_title", "Remapeador de Teclas Pro",
            "subtitle", "Remapeo predictivo + IA",
            "mapping_hdr", "Tecla usable  ->  Grupo de salida (separado por comas)",
            "col_pressable", "Tecla", "col_outputs", "Salidas", "col_current", "Actual",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Usos",
            "btn_add", "Añadir / Editar", "btn_remove", "Eliminar", "btn_clear", "Borrar todo",
            "btn_export", "Exportar", "btn_import", "Importar",
            "mode_lbl", "Modo actual:", "mode_normal", "  NORMAL - APAGADO", "mode_mapped", "  MAPEADO - ON",
            "chk_hud", "Mostrar HUD de predicción",
            "btn_toggle", "Activar mapeo (F12)", "btn_toggle_off", "Desactivar mapeo (F12)",
            "btn_wizard", "Asistente", "btn_stats", "Estadísticas",
            "lang_lbl", "Idioma:",
            "hotkeys", "F12 alternar  |  F11 pausa  |  Ctrl+F12 añadir  |  Ctrl+Shift+Z deshacer  |  Tab completar  |  Repetir tecla para alternar",
            "tray_show", "Mostrar ventana", "tray_toggle", "Mapeo (F12)", "tray_pause", "Pausa (F11)",
            "tray_stats", "Estadísticas...", "tray_wizard", "Asistente", "tray_exit", "Salir",
            "hud_cycle", "Pulse la misma tecla otra vez para alternar"
        ),
        "fr", Map(
            "app_title", "Remappeur de Touches Pro",
            "subtitle", "Remappage prédictif + IA",
            "mapping_hdr", "Touche utilisable  ->  Groupe de sortie (séparé par des virgules)",
            "col_pressable", "Touche", "col_outputs", "Sorties", "col_current", "Actuel",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Uses",
            "btn_add", "Ajouter", "btn_remove", "Supprimer", "btn_clear", "Tout effacer",
            "btn_export", "Exporter", "btn_import", "Importer",
            "mode_lbl", "Mode :", "mode_normal", "  NORMAL - OFF", "mode_mapped", "  MAPPÉ - ON",
            "chk_hud", "Afficher le HUD de prédiction",
            "btn_toggle", "Activer mappage (F12)", "btn_toggle_off", "Désactiver mappage (F12)",
            "btn_wizard", "Assistant", "btn_stats", "Statistiques",
            "lang_lbl", "Langue :",
            "hotkeys", "F12 basculer  |  F11 pause  |  Ctrl+F12 ajouter  |  Ctrl+Shift+Z annuler  |  Tab compléter  |  Reappuyer pour alterner",
            "tray_show", "Afficher", "tray_toggle", "Mappage (F12)", "tray_pause", "Pause (F11)",
            "tray_stats", "Statistiques...", "tray_wizard", "Assistant", "tray_exit", "Quitter",
            "hud_cycle", "Reappuyez sur la même touche pour alterner"
        ),
        "de", Map(
            "app_title", "Tasten-Remapper Pro",
            "subtitle", "Intelligentes Remapping + KI",
            "mapping_hdr", "Funktionstaste  ->  Ausgabegruppe (kommagetrennt)",
            "col_pressable", "Taste", "col_outputs", "Ausgaben", "col_current", "Aktuell",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Nutzung",
            "btn_add", "Hinzufügen", "btn_remove", "Entfernen", "btn_clear", "Alles löschen",
            "btn_export", "Export", "btn_import", "Import",
            "mode_lbl", "Modus:", "mode_normal", "  NORMAL - AUS", "mode_mapped", "  MAP - AN",
            "chk_hud", "Vorhersage-HUD anzeigen",
            "btn_toggle", "Mapping AN (F12)", "btn_toggle_off", "Mapping AUS (F12)",
            "btn_wizard", "Assistent", "btn_stats", "Statistik",
            "lang_lbl", "Sprache:",
            "hotkeys", "F12 umschalten  |  F11 Pause  |  Ctrl+F12 hinzufügen  |  Ctrl+Shift+Z rückgängig  |  Tab vervollständigen  |  Taste erneut = wechseln",
            "tray_show", "Fenster zeigen", "tray_toggle", "Mapping (F12)", "tray_pause", "Pause (F11)",
            "tray_stats", "Statistik...", "tray_wizard", "Assistent", "tray_exit", "Beenden",
            "hud_cycle", "Gleiche Taste erneut drücken zum Wechseln"
        ),
        "zh", Map(
            "app_title", "坏键重映射 Pro",
            "subtitle", "智能预测重映射 + AI",
            "mapping_hdr", "可用键  ->  输出组（逗号分隔）",
            "col_pressable", "按键", "col_outputs", "输出", "col_current", "当前",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "次数",
            "btn_add", "添加/编辑", "btn_remove", "删除", "btn_clear", "全部清除",
            "btn_export", "导出", "btn_import", "导入",
            "mode_lbl", "当前模式：", "mode_normal", "  普通模式 - 关", "mode_mapped", "  映射模式 - 开",
            "chk_hud", "显示浮动预测 HUD",
            "btn_toggle", "开启映射 (F12)", "btn_toggle_off", "关闭映射 (F12)",
            "btn_wizard", "设置向导", "btn_stats", "统计",
            "lang_lbl", "语言：",
            "hotkeys", "F12 切换  |  F11 暂停  |  Ctrl+F12 添加  |  Ctrl+Shift+Z 撤销  |  Tab 补全  |  再按同一键循环",
            "tray_show", "显示窗口", "tray_toggle", "映射 (F12)", "tray_pause", "暂停 (F11)",
            "tray_stats", "统计...", "tray_wizard", "向导", "tray_exit", "退出",
            "hud_cycle", "再按同一键切换字母"
        ),
        "ja", Map(
            "app_title", "壊れたキーリマッパー Pro",
            "subtitle", "予測リマップ + AI",
            "mapping_hdr", "使用可能キー  ->  出力グループ（カンマ区切り）",
            "col_pressable", "キー", "col_outputs", "出力", "col_current", "現在",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "回数",
            "btn_add", "追加/編集", "btn_remove", "削除", "btn_clear", "すべて削除",
            "btn_export", "エクスポート", "btn_import", "インポート",
            "mode_lbl", "モード：", "mode_normal", "  通常 - OFF", "mode_mapped", "  マップ - ON",
            "chk_hud", "予測 HUD を表示",
            "btn_toggle", "マップ ON (F12)", "btn_toggle_off", "マップ OFF (F12)",
            "btn_wizard", "セットアップ", "btn_stats", "統計",
            "lang_lbl", "言語：",
            "hotkeys", "F12 切替  |  F11 一時停止  |  Ctrl+F12 追加  |  Ctrl+Shift+Z 元に戻す  |  Tab 補完  |  同じキーで循環",
            "tray_show", "ウィンドウ", "tray_toggle", "マップ (F12)", "tray_pause", "一時停止 (F11)",
            "tray_stats", "統計...", "tray_wizard", "セットアップ", "tray_exit", "終了",
            "hud_cycle", "同じキーをもう一度押して切替"
        ),
        "pt", Map(
            "app_title", "Remapeador de Teclas Pro",
            "subtitle", "Remapeamento preditivo + IA",
            "mapping_hdr", "Tecla funcional  ->  Grupo de saída (vírgulas)",
            "col_pressable", "Tecla", "col_outputs", "Saídas", "col_current", "Atual",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Usos",
            "btn_add", "Adicionar", "btn_remove", "Remover", "btn_clear", "Limpar tudo",
            "btn_export", "Exportar", "btn_import", "Importar",
            "mode_lbl", "Modo:", "mode_normal", "  NORMAL - OFF", "mode_mapped", "  MAPEADO - ON",
            "chk_hud", "Mostrar HUD de previsão",
            "btn_toggle", "Ativar mapeamento (F12)", "btn_toggle_off", "Desativar mapeamento (F12)",
            "btn_wizard", "Assistente", "btn_stats", "Estatísticas",
            "lang_lbl", "Idioma:",
            "hotkeys", "F12 alternar  |  F11 pausar  |  Ctrl+F12 adicionar  |  Ctrl+Shift+Z desfazer  |  Tab completar  |  Repetir tecla para alternar",
            "tray_show", "Mostrar janela", "tray_toggle", "Mapeamento (F12)", "tray_pause", "Pausa (F11)",
            "tray_stats", "Estatísticas...", "tray_wizard", "Assistente", "tray_exit", "Sair",
            "hud_cycle", "Pressione a mesma tecla novamente para alternar"
        ),
        "ar", Map(
            "app_title", "معيد تعيين المفاتيح Pro",
            "subtitle", "إعادة تعيين ذكية + ذكاء اصطناعي",
            "mapping_hdr", "المفتاح العامل  ->  مجموعة الإخراج (مفصولة بفاصلة)",
            "col_pressable", "مفتاح", "col_outputs", "مخرجات", "col_current", "الحالي",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "استخدام",
            "btn_add", "إضافة", "btn_remove", "حذف", "btn_clear", "مسح الكل",
            "btn_export", "تصدير", "btn_import", "استيراد",
            "mode_lbl", "الوضع:", "mode_normal", "  عادي - إيقاف", "mode_mapped", "  تعيين - تشغيل",
            "chk_hud", "إظهار HUD التنبؤ",
            "btn_toggle", "تشغيل التعيين (F12)", "btn_toggle_off", "إيقاف التعيين (F12)",
            "btn_wizard", "معالج الإعداد", "btn_stats", "إحصائيات",
            "lang_lbl", "اللغة:",
            "hotkeys", "F12 تبديل  |  F11 إيقاف مؤقت  |  Ctrl+F12 إضافة  |  Ctrl+Shift+Z تراجع  |  Tab إكمال  |  اضغط نفس المفتاح للتبديل",
            "tray_show", "إظهار النافذة", "tray_toggle", "تعيين (F12)", "tray_pause", "إيقاف مؤقت (F11)",
            "tray_stats", "إحصائيات...", "tray_wizard", "معالج", "tray_exit", "خروج",
            "hud_cycle", "اضغط نفس المفتاح مرة أخرى للتبديل"
        ),
        "uk", Map(
            "app_title", "Ремапер зламаних клавіш Pro",
            "subtitle", "Розумне передбачення + ШІ",
            "mapping_hdr", "Робоча клавіша  ->  Група виводу (через кому)",
            "col_pressable", "Клавіша", "col_outputs", "Вивід", "col_current", "Зараз",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Вик.",
            "btn_add", "Додати", "btn_remove", "Видалити", "btn_clear", "Очистити",
            "btn_export", "Експорт", "btn_import", "Імпорт",
            "mode_lbl", "Режим:", "mode_normal", "  ЗВИЧАЙНИЙ - ВИМК", "mode_mapped", "  РЕМАП - УВІМК",
            "chk_hud", "Показувати HUD передбачень",
            "btn_toggle", "Увімкнути ремап (F12)", "btn_toggle_off", "Вимкнути ремап (F12)",
            "btn_wizard", "Майстер", "btn_stats", "Статистика",
            "lang_lbl", "Мова:",
            "hotkeys", "F12 перемкнути  |  F11 пауза  |  Ctrl+F12 додати  |  Ctrl+Shift+Z скасувати  |  Tab доповнити  |  Повтор клавіші — перебір",
            "tray_show", "Показати вікно", "tray_toggle", "Ремап (F12)", "tray_pause", "Пауза (F11)",
            "tray_stats", "Статистика...", "tray_wizard", "Майстер", "tray_exit", "Вихід",
            "hud_cycle", "Натисніть ту саму клавішу знову"
        ),
        "it", Map(
            "app_title", "Remapper Tasti Pro",
            "subtitle", "Rimapping predittivo + IA",
            "mapping_hdr", "Tasto funzionante  ->  Gruppo output (virgole)",
            "col_pressable", "Tasto", "col_outputs", "Output", "col_current", "Attuale",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Usi",
            "btn_add", "Aggiungi", "btn_remove", "Rimuovi", "btn_clear", "Cancella tutto",
            "btn_export", "Esporta", "btn_import", "Importa",
            "mode_lbl", "Modalità:", "mode_normal", "  NORMALE - OFF", "mode_mapped", "  MAPPATO - ON",
            "chk_hud", "Mostra HUD previsioni",
            "btn_toggle", "Attiva mapping (F12)", "btn_toggle_off", "Disattiva mapping (F12)",
            "btn_wizard", "Procedura guidata", "btn_stats", "Statistiche",
            "lang_lbl", "Lingua:",
            "hotkeys", "F12 toggle  |  F11 pausa  |  Ctrl+F12 aggiungi  |  Ctrl+Shift+Z annulla  |  Tab completa  |  Ripeti tasto per ciclare",
            "tray_show", "Mostra finestra", "tray_toggle", "Mapping (F12)", "tray_pause", "Pausa (F11)",
            "tray_stats", "Statistiche...", "tray_wizard", "Guidata", "tray_exit", "Esci",
            "hud_cycle", "Premi di nuovo lo stesso tasto per ciclare"
        ),
        "ko", Map(
            "app_title", "키 리매퍼 Pro",
            "subtitle", "스마트 예측 리매핑 + AI",
            "mapping_hdr", "사용 가능 키  ->  출력 그룹 (쉼표 구분)",
            "col_pressable", "키", "col_outputs", "출력", "col_current", "현재",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "횟수",
            "btn_add", "추가/편집", "btn_remove", "삭제", "btn_clear", "전체 삭제",
            "btn_export", "내보내기", "btn_import", "가져오기",
            "mode_lbl", "모드:", "mode_normal", "  일반 - OFF", "mode_mapped", "  매핑 - ON",
            "chk_hud", "예측 HUD 표시",
            "btn_toggle", "매핑 켜기 (F12)", "btn_toggle_off", "매핑 끄기 (F12)",
            "btn_wizard", "설정 마법사", "btn_stats", "통계",
            "lang_lbl", "언어:",
            "hotkeys", "F12 전환  |  F11 일시정지  |  Ctrl+F12 추가  |  Ctrl+Shift+Z 실행취소  |  Tab 완성  |  같은 키로 순환",
            "tray_show", "창 표시", "tray_toggle", "매핑 (F12)", "tray_pause", "일시정지 (F11)",
            "tray_stats", "통계...", "tray_wizard", "마법사", "tray_exit", "종료",
            "hud_cycle", "같은 키를 다시 눌러 순환"
        ),
        "hi", Map(
            "app_title", "टूटी कुंजी रीमैपर Pro",
            "subtitle", "स्मार्ट पूर्वानुमान + AI",
            "mapping_hdr", "कार्यशील कुंजी  ->  आउटपुट समूह (अल्पविराम)",
            "col_pressable", "कुंजी", "col_outputs", "आउटपुट", "col_current", "वर्तमान",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "उपयोग",
            "btn_add", "जोड़ें", "btn_remove", "हटाएं", "btn_clear", "सब साफ़",
            "btn_export", "निर्यात", "btn_import", "आयात",
            "mode_lbl", "मोड:", "mode_normal", "  सामान्य - बंद", "mode_mapped", "  मैप - चालू",
            "chk_hud", "भविष्यवाणी HUD दिखाएं",
            "btn_toggle", "मैप चालू (F12)", "btn_toggle_off", "मैप बंद (F12)",
            "btn_wizard", "सेटअप विज़ार्ड", "btn_stats", "आंकड़े",
            "lang_lbl", "भाषा:",
            "hotkeys", "F12 टॉगल  |  F11 रोकें  |  Ctrl+F12 जोड़ें  |  Ctrl+Shift+Z पूर्ववत  |  Tab पूर्ण  |  दोबारा दबाएं चक्र",
            "tray_show", "विंडो", "tray_toggle", "मैप (F12)", "tray_pause", "रोकें (F11)",
            "tray_stats", "आंकड़े...", "tray_wizard", "विज़ार्ड", "tray_exit", "बाहर",
            "hud_cycle", "चक्र के लिए वही कुंजी दोबारा दबाएं"
        ),
        "pl", Map(
            "app_title", "Remapper Klawiszy Pro",
            "subtitle", "Inteligentne mapowanie + AI",
            "mapping_hdr", "Działający klawisz  ->  Grupa wyjścia (przecinki)",
            "col_pressable", "Klawisz", "col_outputs", "Wyjścia", "col_current", "Aktualny",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Użycia",
            "btn_add", "Dodaj", "btn_remove", "Usuń", "btn_clear", "Wyczyść",
            "btn_export", "Eksport", "btn_import", "Import",
            "mode_lbl", "Tryb:", "mode_normal", "  NORMALNY - OFF", "mode_mapped", "  MAPOWANIE - ON",
            "chk_hud", "Pokaż HUD predykcji",
            "btn_toggle", "Włącz mapowanie (F12)", "btn_toggle_off", "Wyłącz mapowanie (F12)",
            "btn_wizard", "Kreator", "btn_stats", "Statystyki",
            "lang_lbl", "Język:",
            "hotkeys", "F12 przełącz  |  F11 pauza  |  Ctrl+F12 dodaj  |  Ctrl+Shift+Z cofnij  |  Tab uzupełnij  |  Powtórz klawisz",
            "tray_show", "Pokaż okno", "tray_toggle", "Mapowanie (F12)", "tray_pause", "Pauza (F11)",
            "tray_stats", "Statystyki...", "tray_wizard", "Kreator", "tray_exit", "Wyjdź",
            "hud_cycle", "Naciśnij ten sam klawisz ponownie"
        ),
        "tr", Map(
            "app_title", "Tuş Yeniden Eşleyici Pro",
            "subtitle", "Akıllı tahmin + YZ",
            "mapping_hdr", "Çalışan tuş  ->  Çıktı grubu (virgülle)",
            "col_pressable", "Tuş", "col_outputs", "Çıktılar", "col_current", "Şu an",
            "col_vk", "VK", "col_sc", "SC", "col_uses", "Kullanım",
            "btn_add", "Ekle", "btn_remove", "Kaldır", "btn_clear", "Temizle",
            "btn_export", "Dışa aktar", "btn_import", "İçe aktar",
            "mode_lbl", "Mod:", "mode_normal", "  NORMAL - KAPALI", "mode_mapped", "  EŞLEME - AÇIK",
            "chk_hud", "Tahmin HUD göster",
            "btn_toggle", "Eşlemeyi aç (F12)", "btn_toggle_off", "Eşlemeyi kapat (F12)",
            "btn_wizard", "Sihirbaz", "btn_stats", "İstatistik",
            "lang_lbl", "Dil:",
            "hotkeys", "F12 aç/kapa  |  F11 duraklat  |  Ctrl+F12 ekle  |  Ctrl+Shift+Z geri al  |  Tab tamamla  |  Aynı tuşa bas = döngü",
            "tray_show", "Pencereyi göster", "tray_toggle", "Eşleme (F12)", "tray_pause", "Duraklat (F11)",
            "tray_stats", "İstatistik...", "tray_wizard", "Sihirbaz", "tray_exit", "Çıkış",
            "hud_cycle", "Döngü için aynı tuşa tekrar basın"
        )
    )
    return T
}

LangOptions() {
    return [
        { code: "en", label: "English" },
        { code: "ru", label: "Русский" },
        { code: "es", label: "Español" },
        { code: "fr", label: "Français" },
        { code: "de", label: "Deutsch" },
        { code: "zh", label: "中文" },
        { code: "ja", label: "日本語" },
        { code: "ko", label: "한국어" },
        { code: "pt", label: "Português" },
        { code: "ar", label: "العربية" },
        { code: "uk", label: "Українська" },
        { code: "it", label: "Italiano" },
        { code: "hi", label: "हिन्दी" },
        { code: "pl", label: "Polski" },
        { code: "tr", label: "Türkçe" }
    ]
}

T(key) {
    global uiLang
    data := I18nData()
    if !data.Has(uiLang)
        uiLang := "en"
    langMap := data[uiLang]
    return langMap.Has(key) ? langMap[key] : (data["en"].Has(key) ? data["en"][key] : key)
}

SetListViewColumnHeader(lv, colIndex, text) {
    ; Disabled — dynamic header updates caused column corruption in some builds.
}

ApplyLanguage(langCode := "") {
    global uiLang, GuiObj, remapMode
    if (langCode != "")
        uiLang := langCode

    if !IsObject(GuiObj)
        return

    GuiObj.Title := T("app_title")
    try GuiObj["TxtTitle"].Text := "  " T("app_title")
    try GuiObj["TxtSubtitle"].Text := "  " T("subtitle")
    try GuiObj["TxtMappingHdr"].Text := T("mapping_hdr")
    try GuiObj["TxtModeLbl"].Text := T("mode_lbl")
    try GuiObj["ChkHud"].Text := T("chk_hud")
    try GuiObj["TxtHotkeys"].Text := T("hotkeys")
    try GuiObj["TxtLangLbl"].Text := T("lang_lbl")

    try GuiObj["BtnAdd"].Text := T("btn_add")
    try GuiObj["BtnRemove"].Text := T("btn_remove")
    try GuiObj["BtnClear"].Text := T("btn_clear")
    try GuiObj["BtnExport"].Text := T("btn_export")
    try GuiObj["BtnImport"].Text := T("btn_import")
    try GuiObj["BtnWizard"].Text := T("btn_wizard")
    try GuiObj["BtnStats"].Text := T("btn_stats")

    UpdateModeDisplay()
    BuildTrayMenu()
    for i, opt in LangOptions() {
        if (opt.code = uiLang) {
            try GuiObj["LangSelect"].Choose(i)
            break
        }
    }
    SaveSettings()
}

OnLanguageChanged(*) {
    global GuiObj, uiLang
    label := GuiObj["LangSelect"].Text
    for , opt in LangOptions() {
        if (opt.label = label) {
            uiLang := opt.code
            break
        }
    }
    ApplyLanguage(uiLang)
}
