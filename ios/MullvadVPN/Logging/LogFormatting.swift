//
//  LogFormatting.swift
//  LogFormatting
//
//  Created by pronebird on 09/09/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import Foundation

extension TimeInterval {
    func logFormatDuration(allowedUnits: NSCalendar.Unit, unitsStyle: DateComponentsFormatter.UnitsStyle = .full, maximumUnitCount: Int = 1) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = unitsStyle
        formatter.allowedUnits = allowedUnits
        formatter.maximumUnitCount = maximumUnitCount

        return formatter.string(from: self) ?? "(nil)"
    }
}

extension Date {
    func logFormatDate() -> String {
        return ISO8601DateFormatter().string(from: self)
    }
}
