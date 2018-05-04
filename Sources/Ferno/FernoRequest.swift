import Vapor
import JWT


struct OAuthBody: Content {
    var grant_type: String
    var assertion: String
}

struct OAuthResponse: Content {
    var access_token: String
    var token_type: String
    var expires_in: Int
}

public protocol FernoRequest {
    func delete(req: Request, method: HTTPMethod, path: [String]) throws -> Future<Bool>
    func send<F: Decodable, T: Content>(req: Request, method: HTTPMethod, path: [String], query: [FernoQuery], body: T, headers: HTTPHeaders) throws -> Future<F>
    func sendMany<F: Decodable, T: Content>(req: Request, method: HTTPMethod, path: [String], query: [FernoQuery], body: T, headers: HTTPHeaders) throws -> Future<[String: F]>
}

public class FernoAPIRequest: FernoRequest {
    private let decoder = JSONDecoder()
    private let httpClient: Client
    private let basePath: String
    private let email: String
    private let privateKey: String
    private var expireDate: Date?
    private var accessToken: String?

    public init(httpClient: Client, basePath: String, email: String, privateKey: String) {
        self.httpClient = httpClient
        self.basePath = basePath
        self.email = email
        self.privateKey = privateKey
        self.expireDate = nil
        self.accessToken = nil
    }

    public func delete(req: Request, method: HTTPMethod, path: [String]) throws -> Future<Bool> {
        return try self.createRequest(method: method, path: path, query: [], body: "", headers: [:]).flatMap({ request in
            return try self.httpClient.respond(to: request).map({ response in
                return response.http.status == .ok
            })
        })
    }

    public func send<F: Decodable, T: Content>(req: Request, method: HTTPMethod, path: [String], query: [FernoQuery], body: T, headers: HTTPHeaders) throws -> Future<F> {
        return try self.createRequest(method: method, path: path, query: query, body: body, headers: headers).flatMap({ (request) in
            return try self.httpClient.respond(to: request).flatMap(to: F.self) { response in
                guard response.http.status == .ok else { throw FernoError.requestFailed }
                return try self.decoder.decode(F.self, from: response.http, maxSize: 65_536, on: req)
            }
        })
    }

    public func sendMany<F: Decodable, T: Content>(req: Request, method: HTTPMethod, path: [String], query: [FernoQuery], body: T, headers: HTTPHeaders) throws -> Future<[String: F]> {
        return try self.createRequest(method: method, path: path, query: query, body: body, headers: headers).flatMap({ (request) in
            return try self.httpClient.respond(to: request).flatMap(to: [String: F].self) { response in
                guard response.http.status == .ok else { throw FernoError.requestFailed }
                return try self.decoder.decode([String: F].self, from: response.http, maxSize: 65_536, on: req)
            }
        })
    }
}

extension FernoAPIRequest {
    private func createRequest<T: Content>(method: HTTPMethod, path: [String], query: [FernoQuery], body: T, headers: HTTPHeaders)throws -> Future<Request> {
        return try getAccessToken().map({ (accessToken) in
            let fernoPath: [FernoPath] = path.makeFernoPath()
            let completePath = self.basePath + fernoPath.childPath
            let queryString = query.createQuery(authKey: accessToken)
            let urlString = "\(completePath)?\(queryString)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let request = Request(using: self.httpClient.container)
            try request.content.encode(body)
            request.http.method = method
            request.http.headers = headers
            request.http.url = URL(string: urlString)!
            return request
        })
    }

    private func createJWT() throws -> Data {
        let header = JWTHeader(alg: "RS256", typ: "JWT")
        let privateSigner = try JWTSigner.rs256(key: .private(pem: self.privateKey))
        let currTime = Date()
        let expireTime = currTime.addingTimeInterval(3600)
        let payload = Payload(iss: .init(value: self.email), scope: ["https://www.googleapis.com/auth/userinfo.email", "https://www.googleapis.com/auth/firebase.database"].joined(separator: " "), aud: "https://www.googleapis.com/oauth2/v4/token", exp: .init(value: expireTime), iat: .init(value: currTime))

        var jwt = JWT(header: header, payload: payload)
        self.expireDate = expireTime

        return try jwt.sign(using: privateSigner)
    }

    private func getAccessToken() throws -> Future<String> {
        if let expireDate = self.expireDate,  Calendar.current.compare(expireDate, to: Date(timeIntervalSinceNow: -120), toGranularity: .second) == .orderedDescending {
            guard let accessToken = self.accessToken else { throw FernoError.invalidAccessToken }
            return Future.map(on: self.httpClient.container) { accessToken }
        }
        //we need to refresh the token
        let jwt = try createJWT()
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded")
        let oauthBody = OAuthBody(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: String.init(data: jwt, encoding: .utf8)!)
        let req = Request(using: self.httpClient.container)
        try req.content.encode(oauthBody, as: .urlEncodedForm)
        req.http.url = URL(string: "https://www.googleapis.com/oauth2/v4/token")!
        req.http.method = .POST
        return try self.httpClient.respond(to: req).flatMap(to: OAuthResponse.self) { result in
            let oauthRes: Future<OAuthResponse> = try result.content.decode(OAuthResponse.self)
            return oauthRes
            }.map(to: String.self) { resp in
                self.accessToken = resp.access_token
                return resp.access_token
        }
    }
}