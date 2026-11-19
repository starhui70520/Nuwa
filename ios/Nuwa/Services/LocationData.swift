import Foundation

struct UserLocation: Codable, Equatable {
    var region: String // ISO code e.g. "CN", "US", "JP", "GB"
    var province: String?
    var city: String?
}

struct LocationProvince: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let cities: [String]
}

enum LocationCatalog {
    static let regions: [(code: String, zh: String, en: String)] = [
        ("CN", "中国大陆", "China"),
        ("HK", "中国香港", "Hong Kong"),
        ("TW", "中国台湾", "Taiwan"),
        ("US", "美国", "United States"),
        ("JP", "日本", "Japan"),
        ("SG", "新加坡", "Singapore"),
        ("GB", "英国", "United Kingdom"),
        ("CA", "加拿大", "Canada"),
        ("AU", "澳大利亚", "Australia"),
        ("DE", "德国", "Germany"),
        ("FR", "法国", "France"),
        ("KR", "韩国", "South Korea"),
    ]

    static let chinaProvinces: [LocationProvince] = [
        LocationProvince(name: "北京市", cities: ["北京市"]),
        LocationProvince(name: "上海市", cities: ["上海市"]),
        LocationProvince(name: "天津市", cities: ["天津市"]),
        LocationProvince(name: "重庆市", cities: ["重庆市"]),
        LocationProvince(name: "广东省", cities: ["广州市", "深圳市", "珠海市", "佛山市", "东莞市", "中山市", "惠州市"]),
        LocationProvince(name: "浙江省", cities: ["杭州市", "宁波市", "温州市", "嘉兴市", "绍兴市", "金华市"]),
        LocationProvince(name: "江苏省", cities: ["南京市", "苏州市", "无锡市", "常州市", "南通市", "徐州市"]),
        LocationProvince(name: "四川省", cities: ["成都市", "绵阳市", "德阳市", "宜宾市", "乐山市"]),
        LocationProvince(name: "湖北省", cities: ["武汉市", "宜昌市", "襄阳市", "荆州市"]),
        LocationProvince(name: "湖南省", cities: ["长沙市", "株洲市", "湘潭市", "衡阳市", "岳阳市"]),
        LocationProvince(name: "福建省", cities: ["福州市", "厦门市", "泉州市", "漳州市"]),
        LocationProvince(name: "山东省", cities: ["济南市", "青岛市", "烟台市", "潍坊市", "威海市"]),
        LocationProvince(name: "河南省", cities: ["郑州市", "洛阳市", "开封市", "南阳市"]),
        LocationProvince(name: "河北省", cities: ["石家庄市", "唐山市", "保定市", "廊坊市", "秦皇岛市"]),
        LocationProvince(name: "陕西省", cities: ["西安市", "咸阳市", "宝鸡市", "延安市"]),
        LocationProvince(name: "辽宁省", cities: ["沈阳市", "大连市", "鞍山市"]),
        LocationProvince(name: "吉林省", cities: ["长春市", "吉林市"]),
        LocationProvince(name: "黑龙江省", cities: ["哈尔滨市", "齐齐哈尔市", "大庆市"]),
        LocationProvince(name: "安徽省", cities: ["合肥市", "芜湖市", "蚌埠市"]),
        LocationProvince(name: "江西省", cities: ["南昌市", "赣州市", "九江市"]),
        LocationProvince(name: "云南省", cities: ["昆明市", "大理市", "丽江市"]),
        LocationProvince(name: "贵州省", cities: ["贵阳市", "遵义市"]),
        LocationProvince(name: "广西壮族自治区", cities: ["南宁市", "桂林市", "柳州市"]),
        LocationProvince(name: "山西省", cities: ["太原市", "大同市"]),
        LocationProvince(name: "内蒙古自治区", cities: ["呼和浩特市", "包头市"]),
        LocationProvince(name: "海南省", cities: ["海口市", "三亚市"]),
        LocationProvince(name: "甘肃省", cities: ["兰州市", "天水市"]),
        LocationProvince(name: "新疆维吾尔自治区", cities: ["乌鲁木齐市"]),
        LocationProvince(name: "宁夏回族自治区", cities: ["银川市"]),
        LocationProvince(name: "青海省", cities: ["西宁市"]),
        LocationProvince(name: "西藏自治区", cities: ["拉萨市"]),
    ]

    static func displayName(for location: UserLocation?, locale: AppLocale) -> String {
        guard let location else { return locale == .zhCN ? "未设置" : "Not set" }
        if location.region == "CN" && locale == .zhCN {
            if let city = location.city, !city.isEmpty {
                return city
            }
            if let prov = location.province, !prov.isEmpty {
                return prov
            }
        }
        if let found = regions.first(where: { $0.code == location.region }) {
            return locale == .zhCN ? found.zh : found.en
        }
        return location.region
    }

    static func createLatestReminder(locale: AppLocale, location: UserLocation?, now: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: now)

        let wf = DateFormatter()
        wf.locale = Locale(identifier: locale.rawValue)
        wf.dateFormat = "EEEE"
        let weekday = wf.string(from: now)

        let locName = location != nil ? displayName(for: location, locale: locale) : ""
        let langName = locale == .zhCN ? "中文" : "English"
        return [dateStr, weekday, locName, "iOS", langName].joined(separator: ",")
    }
}
