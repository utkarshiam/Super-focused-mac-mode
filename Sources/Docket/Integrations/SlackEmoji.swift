import Foundation

/// Slack keeps every emoji in a message as its name (":tada:", ":+1::skin-tone-3:"), even ones typed as
/// emoji. These are the common ones; anything else, a workspace's own emoji included, stays as written.
enum SlackEmoji {
    /// ":tada: done :+1::skin-tone-3:" → "🎉 done 👍🏽". Unknown names are left alone.
    static func replacingShortcodes(in text: String) -> String {
        guard text.contains(":") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in shortcode.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let glyph = emoji(named: ns.substring(with: m.range(at: 1)),
                                    skinTone: m.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 2)))) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + glyph
            last = m.range.location + m.range.length
        }
        guard last > 0 else { return text }
        return out + ns.substring(from: last)
    }

    /// The emoji for a Slack name ("thumbsup", "flag-gb"), with a skin tone (2–6) when it takes one.
    static func emoji(named name: String, skinTone: Int? = nil) -> String? {
        let base: String
        if let known = table[name] {
            base = known
        } else if let flag = flag(name) {
            base = flag
        } else {
            return nil
        }
        guard let tone = skinTone, (2...6).contains(tone), let first = base.unicodeScalars.first, first.properties.isEmojiModifierBase,
              let modifier = Unicode.Scalar(0x1F3FB + UInt32(tone - 2)) else { return base }
        // The modifier replaces the emoji-style selector: "✌️" + 🏽 is "✌🏽".
        var scalars = String.UnicodeScalarView(base.unicodeScalars.filter { $0 != "\u{FE0F}" })
        scalars.insert(modifier, at: scalars.index(after: scalars.startIndex))
        return String(scalars)
    }

    private static let shortcode = try! NSRegularExpression(pattern: #":([a-z0-9_+'\-]+):(?::skin-tone-([2-6]):)?"#)

    /// "flag-gb" → 🇬🇧 (Slack's names for country flags).
    private static func flag(_ name: String) -> String? {
        guard name.hasPrefix("flag-") else { return nil }
        let code = name.dropFirst(5).uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
    }

    /// Slack's names (and its aliases) for the emoji people use most at work.
    private static let table: [String: String] = {
        var t: [String: String] = [
            // Faces
            "grinning": "😀", "smiley": "😃", "smile": "😄", "grin": "😁", "laughing": "😆", "satisfied": "😆",
            "sweat_smile": "😅", "rolling_on_the_floor_laughing": "🤣", "rofl": "🤣", "joy": "😂", "slightly_smiling_face": "🙂",
            "upside_down_face": "🙃", "melting_face": "🫠", "wink": "😉", "blush": "😊", "innocent": "😇",
            "smiling_face_with_3_hearts": "🥰", "heart_eyes": "😍", "star-struck": "🤩", "kissing_heart": "😘", "relaxed": "☺",
            "yum": "😋", "stuck_out_tongue": "😛", "stuck_out_tongue_winking_eye": "😜", "zany_face": "🤪",
            "stuck_out_tongue_closed_eyes": "😝", "money_mouth_face": "🤑", "hugging_face": "🤗", "hugs": "🤗",
            "face_with_hand_over_mouth": "🤭", "shushing_face": "🤫", "thinking_face": "🤔", "thinking": "🤔", "saluting_face": "🫡",
            "zipper_mouth_face": "🤐", "face_with_raised_eyebrow": "🤨", "neutral_face": "😐", "expressionless": "😑",
            "no_mouth": "😶", "smirk": "😏", "unamused": "😒", "face_with_rolling_eyes": "🙄", "roll_eyes": "🙄",
            "grimacing": "😬", "relieved": "😌", "pensive": "😔", "sleepy": "😪", "drooling_face": "🤤", "sleeping": "😴",
            "mask": "😷", "face_with_thermometer": "🤒", "face_with_head_bandage": "🤕", "nauseated_face": "🤢",
            "sneezing_face": "🤧", "hot_face": "🥵", "cold_face": "🥶", "woozy_face": "🥴", "dizzy_face": "😵",
            "exploding_head": "🤯", "cowboy_hat_face": "🤠", "partying_face": "🥳", "sunglasses": "😎", "nerd_face": "🤓",
            "face_with_monocle": "🧐", "confused": "😕", "worried": "😟", "slightly_frowning_face": "🙁",
            "white_frowning_face": "☹", "frowning_face": "☹", "open_mouth": "😮", "hushed": "😯", "astonished": "😲",
            "flushed": "😳", "pleading_face": "🥺", "face_holding_back_tears": "🥹", "frowning": "😦", "anguished": "😧",
            "fearful": "😨", "cold_sweat": "😰", "disappointed_relieved": "😥", "cry": "😢", "sob": "😭", "scream": "😱",
            "confounded": "😖", "persevere": "😣", "disappointed": "😞", "sweat": "😓", "weary": "😩", "tired_face": "😫",
            "yawning_face": "🥱", "triumph": "😤", "rage": "😡", "angry": "😠", "face_with_symbols_on_mouth": "🤬",
            "smiling_imp": "😈", "skull": "💀", "hankey": "💩", "poop": "💩", "clown_face": "🤡", "ghost": "👻",
            "alien": "👽", "robot_face": "🤖", "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊",
            // Hearts and marks
            "heart": "❤", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚", "blue_heart": "💙",
            "purple_heart": "💜", "black_heart": "🖤", "white_heart": "🤍", "brown_heart": "🤎", "broken_heart": "💔",
            "two_hearts": "💕", "sparkling_heart": "💖", "heartpulse": "💗", "heartbeat": "💓", "revolving_hearts": "💞",
            "100": "💯", "anger": "💢", "boom": "💥", "collision": "💥", "dizzy": "💫", "sweat_drops": "💦", "dash": "💨",
            "speech_balloon": "💬", "thought_balloon": "💭", "zzz": "💤",
            // Hands and people
            "wave": "👋", "raised_back_of_hand": "🤚", "raised_hand": "✋", "hand": "✋", "spock-hand": "🖖",
            "ok_hand": "👌", "pinching_hand": "🤏", "v": "✌", "crossed_fingers": "🤞", "i_love_you_hand_sign": "🤟",
            "the_horns": "🤘", "sign_of_the_horns": "🤘", "metal": "🤘", "call_me_hand": "🤙", "point_left": "👈",
            "point_right": "👉", "point_up_2": "👆", "point_down": "👇", "point_up": "☝", "+1": "👍", "thumbsup": "👍",
            "-1": "👎", "thumbsdown": "👎", "fist": "✊", "fist_raised": "✊", "facepunch": "👊", "punch": "👊",
            "left-facing_fist": "🤛", "right-facing_fist": "🤜", "clap": "👏", "raised_hands": "🙌", "heart_hands": "🫶",
            "open_hands": "👐", "palms_up_together": "🤲", "handshake": "🤝", "pray": "🙏", "writing_hand": "✍",
            "nail_care": "💅", "muscle": "💪", "eyes": "👀", "eye": "👁", "brain": "🧠", "bow": "🙇", "face_palm": "🤦",
            "facepalm": "🤦", "shrug": "🤷", "raising_hand": "🙋", "dancer": "💃", "man_dancing": "🕺", "runner": "🏃",
            "running": "🏃", "walking": "🚶", "speaking_head_in_silhouette": "🗣", "bust_in_silhouette": "👤",
            "busts_in_silhouette": "👥",
            // Work and things
            "tada": "🎉", "confetti_ball": "🎊", "balloon": "🎈", "gift": "🎁", "birthday": "🎂", "trophy": "🏆",
            "sports_medal": "🏅", "medal": "🏅", "first_place_medal": "🥇", "second_place_medal": "🥈", "third_place_medal": "🥉",
            "star": "⭐", "star2": "🌟", "sparkles": "✨", "zap": "⚡", "fire": "🔥", "rocket": "🚀", "dart": "🎯",
            "bulb": "💡", "memo": "📝", "pencil": "📝", "pencil2": "✏", "calendar": "📆", "date": "📅",
            "spiral_calendar_pad": "🗓", "spiral_note_pad": "🗒", "clipboard": "📋", "pushpin": "📌", "round_pushpin": "📍",
            "paperclip": "📎", "link": "🔗", "bookmark": "🔖", "bookmark_tabs": "📑", "label": "🏷", "books": "📚",
            "book": "📖", "open_book": "📖", "notebook": "📓", "newspaper": "📰", "page_facing_up": "📄",
            "page_with_curl": "📃", "file_folder": "📁", "open_file_folder": "📂", "card_index_dividers": "🗂",
            "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉", "bar_chart": "📊", "moneybag": "💰",
            "money_with_wings": "💸", "dollar": "💵", "euro": "💶", "pound": "💷", "yen": "💴", "credit_card": "💳",
            "heavy_dollar_sign": "💲", "gem": "💎", "briefcase": "💼", "email": "📧", "e-mail": "📧", "envelope": "✉",
            "incoming_envelope": "📨", "envelope_with_arrow": "📩", "inbox_tray": "📥", "outbox_tray": "📤", "package": "📦",
            "mailbox": "📫", "mailbox_with_mail": "📬", "phone": "☎", "telephone": "☎", "telephone_receiver": "📞",
            "iphone": "📱", "calling": "📲", "computer": "💻", "desktop_computer": "🖥", "keyboard": "⌨", "printer": "🖨",
            "floppy_disk": "💾", "battery": "🔋", "electric_plug": "🔌", "lock": "🔒", "unlock": "🔓",
            "closed_lock_with_key": "🔐", "key": "🔑", "hammer": "🔨", "wrench": "🔧", "hammer_and_wrench": "🛠",
            "nut_and_bolt": "🔩", "gear": "⚙", "toolbox": "🧰", "magnet": "🧲", "scissors": "✂", "straight_ruler": "📏",
            "triangular_ruler": "📐", "wastebasket": "🗑", "mag": "🔍", "mag_right": "🔎", "bell": "🔔", "no_bell": "🔕",
            "loudspeaker": "📢", "mega": "📣", "hourglass": "⌛", "hourglass_flowing_sand": "⏳", "alarm_clock": "⏰",
            "stopwatch": "⏱", "watch": "⌚", "shield": "🛡", "scales": "⚖", "pill": "💊", "syringe": "💉",
            "thermometer": "🌡", "test_tube": "🧪", "dna": "🧬", "microscope": "🔬", "telescope": "🔭", "flashlight": "🔦",
            "candle": "🕯", "bomb": "💣", "moyai": "🗿", "crystal_ball": "🔮", "magic_wand": "🪄", "jigsaw": "🧩",
            "mortar_board": "🎓", "crown": "👑", "ring": "💍", "eyeglasses": "👓", "dark_sunglasses": "🕶",
            "necktie": "👔", "shirt": "👕", "tshirt": "👕", "jeans": "👖", "tophat": "🎩", "ticket": "🎫",
            "admission_tickets": "🎟", "microphone": "🎤", "headphones": "🎧", "musical_note": "🎵", "notes": "🎶",
            "camera": "📷", "video_camera": "📹", "movie_camera": "🎥", "tv": "📺", "art": "🎨", "performing_arts": "🎭",
            "clapper": "🎬", "video_game": "🎮", "game_die": "🎲", "christmas_tree": "🎄", "jack_o_lantern": "🎃",
            "fireworks": "🎆", "soccer": "⚽", "basketball": "🏀", "football": "🏈", "baseball": "⚾", "tennis": "🎾",
            "golf": "⛳",
            // Food and drink
            "coffee": "☕", "tea": "🍵", "beer": "🍺", "beers": "🍻", "champagne": "🍾", "wine_glass": "🍷",
            "clinking_glasses": "🥂", "pizza": "🍕", "hamburger": "🍔", "fries": "🍟", "taco": "🌮", "cake": "🍰",
            "cookie": "🍪", "doughnut": "🍩", "popcorn": "🍿", "apple": "🍎", "avocado": "🥑",
            // Places and travel
            "house": "🏠", "office": "🏢", "hospital": "🏥", "bank": "🏦", "hotel": "🏨", "school": "🏫",
            "airplane": "✈", "car": "🚗", "red_car": "🚗", "taxi": "🚕", "ship": "🚢", "construction": "🚧",
            "rotating_light": "🚨", "globe_with_meridians": "🌐", "earth_americas": "🌎", "earth_africa": "🌍",
            "earth_asia": "🌏", "beach_with_umbrella": "🏖", "desert_island": "🏝", "tent": "⛺",
            // Nature
            "sunny": "☀", "cloud": "☁", "partly_sunny": "⛅", "snowflake": "❄", "rainbow": "🌈", "ocean": "🌊",
            "droplet": "💧", "crescent_moon": "🌙", "sun_with_face": "🌞", "seedling": "🌱", "herb": "🌿",
            "four_leaf_clover": "🍀", "evergreen_tree": "🌲", "palm_tree": "🌴", "cactus": "🌵", "rose": "🌹",
            "sunflower": "🌻", "tulip": "🌷", "cherry_blossom": "🌸", "bouquet": "💐", "dog": "🐶", "cat": "🐱",
            "unicorn_face": "🦄", "bee": "🐝", "honeybee": "🐝", "turtle": "🐢", "snail": "🐌", "goat": "🐐",
            "sloth": "🦥", "crab": "🦀", "parrot": "🦜", "owl": "🦉", "fox_face": "🦊", "panda_face": "🐼",
            "monkey_face": "🐵", "penguin": "🐧", "tiger": "🐯", "lion_face": "🦁", "frog": "🐸", "octopus": "🐙",
            "whale": "🐳", "dolphin": "🐬", "shark": "🦈", "butterfly": "🦋", "llama": "🦙", "duck": "🦆", "rabbit": "🐰",
            // Symbols
            "white_check_mark": "✅", "heavy_check_mark": "✔", "ballot_box_with_check": "☑", "x": "❌",
            "negative_squared_cross_mark": "❎", "heavy_multiplication_x": "✖", "warning": "⚠", "no_entry": "⛔",
            "no_entry_sign": "🚫", "exclamation": "❗", "heavy_exclamation_mark": "❗", "grey_exclamation": "❕",
            "question": "❓", "grey_question": "❔", "bangbang": "‼", "interrobang": "⁉", "heavy_plus_sign": "➕",
            "heavy_minus_sign": "➖", "heavy_division_sign": "➗", "arrow_right": "➡", "arrow_left": "⬅", "arrow_up": "⬆",
            "arrow_down": "⬇", "arrow_forward": "▶", "arrow_backward": "◀", "arrow_upper_right": "↗",
            "arrow_lower_right": "↘", "arrows_counterclockwise": "🔄", "repeat": "🔁", "new": "🆕", "free": "🆓",
            "sos": "🆘", "ok": "🆗", "cool": "🆒", "up": "🆙", "red_circle": "🔴", "large_blue_circle": "🔵",
            "blue_circle": "🔵", "large_green_circle": "🟢", "green_circle": "🟢", "large_yellow_circle": "🟡",
            "yellow_circle": "🟡", "large_orange_circle": "🟠", "orange_circle": "🟠", "large_purple_circle": "🟣",
            "purple_circle": "🟣", "white_circle": "⚪", "black_circle": "⚫", "small_red_triangle": "🔺",
            "small_red_triangle_down": "🔻", "large_orange_diamond": "🔶", "large_blue_diamond": "🔷",
            "small_orange_diamond": "🔸", "small_blue_diamond": "🔹", "copyright": "©", "registered": "®", "tm": "™",
            "information_source": "ℹ", "checkered_flag": "🏁", "triangular_flag_on_post": "🚩",
        ]
        // Keycaps: "one" → 1️⃣.
        for (i, name) in ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"].enumerated() {
            t[name] = "\(i)\u{FE0F}\u{20E3}"
        }
        t["keycap_ten"] = "🔟"
        t["hash"] = "#\u{FE0F}\u{20E3}"
        // A symbol that's text by default ("❤", "✔") needs the emoji-style selector to show in colour.
        return t.mapValues { glyph in
            guard glyph.unicodeScalars.count == 1, let scalar = glyph.unicodeScalars.first,
                  !scalar.properties.isEmojiPresentation else { return glyph }
            return glyph + "\u{FE0F}"
        }
    }()
}
