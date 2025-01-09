//
//  Spin.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 12/29/24.
//
import Foundation

public struct Spin: Codable, Sendable {
  let id: String
  let stationId: String
  let airtime: Date
  let createdAt: Date
  let updatedAt: Date
  let audioBlock: AudioBlock?

  // dependency injection
  var dateProvider: DateProvider! = .shared

  var endtime: Date {
    return airtime + TimeInterval((audioBlock?.endOfMessageMS ?? 0) / 1000)
  }

  var isPlaying: Bool {
    return airtime <= dateProvider.now() &&
          dateProvider.now() <= endtime
  }

  private enum CodingKeys: String, CodingKey {
    case id, stationId, airtime, createdAt, updatedAt, audioBlock
  }
}


extension Spin: Equatable {
  public static func ==(lhs: Spin, rhs: Spin) -> Bool {
    return lhs.id == rhs.id &&
    lhs.audioBlock?.id == rhs.audioBlock?.id &&
    lhs.airtime == rhs.airtime
  }
}

extension Spin {
  public static var mock: Spin {
    return Schedule.mock.spins[0]
  }
}
